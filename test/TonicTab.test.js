const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

const DAY = 86400;
const E = (n) => ethers.parseEther(String(n));

describe("TonicTab", function () {
  let tt, owner, merchant, buyer, friend, other;

  beforeEach(async () => {
    [owner, merchant, buyer, friend, other] = await ethers.getSigners();
    const F = await ethers.getContractFactory("TonicTab");
    tt = await F.deploy();
    await tt.waitForDeployment();
  });

  async function openCounter(denom = "0.5", validity = 30 * DAY) {
    await tt.connect(merchant).openCounter("Fennel & Rue Apothecary", E(denom), validity);
    return (await tt.counterCount()) - 1n;
  }
  async function buy(counterId, signer = buyer, denom = "0.5") {
    await tt.connect(signer).buyVoucher(counterId, "for the tonic", { value: E(denom) });
    return (await tt.voucherCount()) - 1n;
  }

  it("opens a counter with its terms", async () => {
    const id = await openCounter();
    const c = await tt.getCounter(id);
    expect(c.merchant).to.equal(merchant.address);
    expect(c.name).to.equal("Fennel & Rue Apothecary");
    expect(c.denomination).to.equal(E("0.5"));
    expect(c.validitySecs).to.equal(30 * DAY);
    expect(c.selling).to.equal(true);
  });

  it("rejects a bad name, a dust denomination and a bad validity", async () => {
    await expect(tt.connect(merchant).openCounter("", E(1), 30 * DAY)).to.be.revertedWith("bad name");
    await expect(tt.connect(merchant).openCounter("x", 1, 30 * DAY)).to.be.revertedWith("denomination too small");
    await expect(tt.connect(merchant).openCounter("x", E(1), 60)).to.be.revertedWith("bad validity");
    await expect(tt.connect(merchant).openCounter("x", E(1), 400 * DAY)).to.be.revertedWith("bad validity");
  });

  it("sells a voucher for the exact denomination and escrows the value", async () => {
    const cid = await openCounter();
    await expect(tt.connect(buyer).buyVoucher(cid, "", { value: E("0.4") })).to.be.revertedWith("wrong amount");

    const vid = await buy(cid);
    const v = await tt.getVoucher(vid);
    expect(v.holder).to.equal(buyer.address);
    expect(v.value).to.equal(E("0.5"));
    expect(v.status).to.equal(0);
    expect(await tt.escrowedTotal()).to.equal(E("0.5"));
    expect((await tt.getCounter(cid)).sold).to.equal(1);
  });

  it("refuses sales once the merchant closes the counter", async () => {
    const cid = await openCounter();
    await tt.connect(merchant).setSelling(cid, false);
    await expect(tt.connect(buyer).buyVoucher(cid, "", { value: E("0.5") })).to.be.revertedWith("counter closed");
    await expect(tt.connect(other).setSelling(cid, true)).to.be.revertedWith("not merchant");
  });

  it("transfers a voucher and keeps both holder lists correct", async () => {
    const cid = await openCounter();
    const a = await buy(cid);
    const b = await buy(cid);

    await expect(tt.connect(other).transferVoucher(a, friend.address)).to.be.revertedWith("not holder");
    await tt.connect(buyer).transferVoucher(a, friend.address);

    expect((await tt.getVoucher(a)).holder).to.equal(friend.address);
    expect((await tt.getVouchersByHolder(friend.address)).map(Number)).to.deep.equal([Number(a)]);
    expect((await tt.getVouchersByHolder(buyer.address)).map(Number)).to.deep.equal([Number(b)]);
  });

  it("will not transfer an expired voucher", async () => {
    const cid = await openCounter();
    const vid = await buy(cid);
    await time.increase(31 * DAY);
    await expect(tt.connect(buyer).transferVoucher(vid, friend.address)).to.be.revertedWith("expired");
  });

  it("pays the merchant on redemption, minus the fee, and only from the holder", async () => {
    const cid = await openCounter();
    const vid = await buy(cid);

    await expect(tt.connect(other).redeemVoucher(vid)).to.be.revertedWith("not holder");

    // 1.5% of 0.5 BOT = 0.0075
    await expect(tt.connect(buyer).redeemVoucher(vid)).to.changeEtherBalance(merchant, E("0.4925"));
    expect(await tt.accumulatedFees()).to.equal(E("0.0075"));
    expect(await tt.escrowedTotal()).to.equal(0);
    expect((await tt.getVoucher(vid)).status).to.equal(1);
    expect((await tt.getCounter(cid)).redeemed).to.equal(1);

    // The holder stays on record for provenance, so a second attempt fails on status.
    await expect(tt.connect(buyer).redeemVoucher(vid)).to.be.revertedWith("not open");
  });

  it("pays the merchant whoever ends up holding the voucher", async () => {
    const cid = await openCounter();
    const vid = await buy(cid);
    await tt.connect(buyer).transferVoucher(vid, friend.address);
    await expect(tt.connect(friend).redeemVoucher(vid)).to.changeEtherBalance(merchant, E("0.4925"));
  });

  it("refuses redemption after expiry", async () => {
    const cid = await openCounter();
    const vid = await buy(cid);
    await time.increase(31 * DAY);
    await expect(tt.connect(buyer).redeemVoucher(vid)).to.be.revertedWith("expired");
  });

  it("refunds an expired voucher in full, with no fee taken", async () => {
    const cid = await openCounter();
    const vid = await buy(cid);
    await expect(tt.connect(buyer).refundExpired(vid)).to.be.revertedWith("not expired");

    await time.increase(31 * DAY);
    await expect(tt.connect(buyer).refundExpired(vid)).to.changeEtherBalance(buyer, E("0.5"));
    expect(await tt.accumulatedFees()).to.equal(0);
    expect(await tt.escrowedTotal()).to.equal(0);
    expect((await tt.getVoucher(vid)).status).to.equal(2);
    expect((await tt.getCounter(cid)).refunded).to.equal(1);
  });

  it("will not refund a voucher that was already spent", async () => {
    const cid = await openCounter();
    const vid = await buy(cid);
    await tt.connect(buyer).redeemVoucher(vid);
    await time.increase(31 * DAY);
    await expect(tt.connect(buyer).refundExpired(vid)).to.be.revertedWith("not open");
  });

  it("repricing a counter leaves vouchers already sold at their original value", async () => {
    const cid = await openCounter();
    const old = await buy(cid);
    await tt.connect(merchant).updateDenomination(cid, E(2));

    expect((await tt.getVoucher(old)).value).to.equal(E("0.5"));
    await expect(tt.connect(buyer).buyVoucher(cid, "", { value: E("0.5") })).to.be.revertedWith("wrong amount");
    await tt.connect(buyer).buyVoucher(cid, "", { value: E(2) });
    expect(await tt.escrowedTotal()).to.equal(E("2.5"));
  });

  it("pauses selling but never traps a voucher", async () => {
    const cid = await openCounter();
    const vid = await buy(cid);
    await tt.connect(owner).pause();

    await expect(tt.connect(buyer).buyVoucher(cid, "", { value: E("0.5") })).to.be.revertedWithCustomError(
      tt,
      "EnforcedPause"
    );
    await tt.connect(buyer).transferVoucher(vid, friend.address);
    await tt.connect(friend).redeemVoucher(vid);
  });

  it("withdraws only fees, owner only, leaving escrow intact", async () => {
    const cid = await openCounter();
    const spent = await buy(cid);
    await buy(cid, friend);
    await tt.connect(buyer).redeemVoucher(spent);

    await expect(tt.connect(other).withdrawFees(other.address)).to.be.revertedWithCustomError(
      tt,
      "OwnableUnauthorizedAccount"
    );
    await expect(tt.connect(owner).withdrawFees(owner.address)).to.changeEtherBalance(owner, E("0.0075"));

    // The unspent voucher's escrow is untouched.
    expect(await ethers.provider.getBalance(await tt.getAddress())).to.equal(E("0.5"));
    expect(await tt.escrowedTotal()).to.equal(E("0.5"));
  });

  it("caps the fee and lists counters newest first", async () => {
    await expect(tt.connect(owner).setFeeBps(900)).to.be.revertedWith("fee too high");
    await tt.connect(owner).setFeeBps(500);
    expect(await tt.feeBps()).to.equal(500);

    await openCounter();
    await openCounter("1");
    await openCounter("2");
    expect((await tt.getRecentCounters(2)).map(Number)).to.deep.equal([2, 1]);
    expect((await tt.getCountersByMerchant(merchant.address)).length).to.equal(3);
  });
});
