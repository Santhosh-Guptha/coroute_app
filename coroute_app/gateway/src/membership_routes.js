'use strict';
const crypto = require('crypto');
const rateLimit = require('express-rate-limit');
const config = require('./config');

const actionLimiter = rateLimit({
  windowMs: 60 * 1000,
  limit: 60,
  standardHeaders: 'draft-7',
  legacyHeaders: false,
  message: { error: 'Too many requests. Please slow down.', reason: 'RATE_LIMITED' },
});

/**
 * Public membership routes: catalog and categories.
 */
function registerMembershipPublicRoutes({ r, repo, wrap }) {
  /**
   * GET /api/membership/catalog
   */
  r.get('/membership/catalog', wrap(async (req, res) => {
    const catalog = await repo.getMembershipCatalog();
    const offers = typeof repo.listOffers === 'function' ? await repo.listOffers(20) : [];
    const activeOffers = offers.filter((o) => o.isActive !== false && (!o.expiresAt || o.expiresAt > Date.now()));
    res.json({
      categories: catalog,
      offers: activeOffers.map((o) => ({
        id: o.id,
        name: o.name || o.id,
        discountType: o.discountType,
        discountPercent: o.discountPercent || o.discountValue,
        description: o.description,
      })),
      paymentsEnabled: config.paymentsEnabled,
    });
  }));
}

/**
 * Authenticated membership routes: purchase, invitations, seat management, admin.
 */
function registerMembershipAuthRoutes({ r, repo, convoys, wrap, requireAdmin }) {
  /**
   * GET /api/membership/my
   */
  r.get('/membership/my', wrap(async (req, res) => {
    const uid = req.user.userId;
    const owned = await repo.findMembershipByOwner(uid);
    const allMemberships = await repo.findMembershipsForUser(uid);
    const participating = allMemberships.filter((m) => m.ownerUserId !== uid);
    const activeTrip = await repo.getActiveTrip(uid);

    let effectiveEntitlements = {
      ptt: false,
      convoy: false,
      groupSafety: false,
      personalTracking: true,
      basicNav: true,
      sharedTrip: false,
    };

    if (config.paymentsEnabled === false) {
      // When payments are disabled by platform admin, all features are unlocked freely.
      effectiveEntitlements = {
        ptt: true,
        convoy: true,
        groupSafety: true,
        personalTracking: true,
        basicNav: true,
        sharedTrip: true,
      };
    } else if (owned && owned.status === 'ACTIVE' && owned.validUntil > Date.now()) {
      const catalog = await repo.getMembershipCatalog();
      const cat = catalog[owned.category];
      if (cat?.entitlements) effectiveEntitlements = { ...effectiveEntitlements, ...cat.entitlements };
    } else if (participating.some((m) => m.status === 'ACTIVE' && m.validUntil > Date.now())) {
      // Participant inherits group entitlements of the owner's active group membership
      effectiveEntitlements = {
        ptt: true,
        convoy: true,
        groupSafety: true,
        personalTracking: true,
        basicNav: true,
        sharedTrip: true,
      };
    }

    res.json({
      owned: owned || null,
      participating,
      activeTrip: activeTrip || null,
      effectiveEntitlements,
      paymentsEnabled: config.paymentsEnabled,
    });
  }));

  /**
   * POST /api/membership/purchase
   */
  r.post('/membership/purchase', actionLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const { category, offerCode, paymentId, orderId } = req.body || {};

    const catalog = await repo.getMembershipCatalog();
    const plan = catalog[category];
    if (!plan) {
      return res.status(400).json({ error: 'Invalid membership category', reason: 'INVALID_CATEGORY' });
    }

    const now = Date.now();
    let isFreeActivation = false;
    let appliedOffer = null;

    if (offerCode) {
      const cleanOffer = String(offerCode).trim().toUpperCase();
      if (typeof repo.findOffer === 'function') {
        const off = await repo.findOffer(cleanOffer);
        if (off && off.isActive !== false && (!off.expiresAt || off.expiresAt > now)) {
          if (off.discountPercent === 100 || off.discountType === 'free') {
            isFreeActivation = true;
            appliedOffer = off.id;
          }
        }
      }
      if (!isFreeActivation && typeof repo.findCoupon === 'function') {
        const coup = await repo.findCoupon(cleanOffer);
        if (coup && coup.isActive !== false && (!coup.expiresAt || coup.expiresAt > now)) {
          if (coup.discountType === 'free' || coup.discountValue === 100) {
            isFreeActivation = true;
            appliedOffer = coup.code;
          }
        }
      }
      if (!isFreeActivation && cleanOffer === 'RIDERFREE') {
        isFreeActivation = true;
        appliedOffer = 'RIDERFREE';
      }
    }

    if (config.paymentsEnabled === false) {
      isFreeActivation = true;
    }

    if (!isFreeActivation && plan.monthlyPriceInr > 0 && !paymentId) {
      return res.status(402).json({
        error: 'Payment required to activate this membership category',
        reason: 'PAYMENT_REQUIRED',
        amountInr: plan.monthlyPriceInr,
      });
    }

    const existing = await repo.findMembershipByOwner(uid);
    let membershipId = existing ? existing.membershipId : `mem_${crypto.randomUUID()}`;
    let members = existing ? (existing.members || {}) : {};

    if (Object.keys(members).length + 1 > plan.capacity) {
      return res.status(409).json({
        error: `Cannot switch to ${plan.name}: current group has ${Object.keys(members).length + 1} members which exceeds new capacity of ${plan.capacity}. Please remove members first.`,
        reason: 'CAPACITY_CONFLICT',
      });
    }

    const durationDays = plan.billingPeriodDays || 30;
    const validUntil = existing && existing.validUntil > now
      ? existing.validUntil + durationDays * 86400000
      : now + durationDays * 86400000;

    const membershipDoc = {
      membershipId,
      ownerUserId: uid, // Permanent owner, non-transferable
      ownerName: req.user.name,
      ownerEmail: req.user.email,
      category,
      categoryName: plan.name,
      capacity: plan.capacity,
      minCapacity: plan.minCapacity || 1,
      maxCapacity: plan.maxCapacity || plan.capacity,
      priceInr: plan.monthlyPriceInr,
      status: 'ACTIVE',
      validFrom: existing ? existing.validFrom : now,
      validUntil,
      members,
      offerApplied: appliedOffer || null,
      paymentId: paymentId || null,
      orderId: orderId || null,
      createdAt: existing ? existing.createdAt : now,
      updatedAt: now,
    };

    await repo.saveMembership(membershipDoc);

    res.status(existing ? 200 : 201).json({
      message: 'Membership activated successfully',
      membership: membershipDoc,
    });
  }));

  /**
   * POST /api/membership/members/invite
   */
  r.post('/membership/members/invite', actionLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const { email, phone, userId: targetUserIdInput } = req.body || {};

    const membership = await repo.findMembershipByOwner(uid);
    if (!membership || membership.status !== 'ACTIVE' || membership.validUntil <= Date.now()) {
      return res.status(403).json({
        error: 'You do not own an active group membership.',
        reason: 'NO_ACTIVE_MEMBERSHIP',
      });
    }

    if (membership.capacity <= 1) {
      return res.status(400).json({
        error: 'Individual memberships do not support group member invitations.',
        reason: 'INDIVIDUAL_TIER_NO_INVITES',
      });
    }

    const members = membership.members || {};
    const occupiedSeats = 1 + Object.keys(members).length; // 1 for owner

    if (occupiedSeats >= membership.capacity) {
      return res.status(409).json({
        error: `Cannot invite more members. Purchased capacity of ${membership.capacity} seats reached.`,
        reason: 'MEMBERSHIP_CAPACITY_EXCEEDED',
        capacity: membership.capacity,
        occupiedSeats,
      });
    }

    let targetUser = null;
    if (targetUserIdInput) {
      targetUser = await repo.findUserById(String(targetUserIdInput));
    } else if (email) {
      targetUser = await repo.findUserByEmail(String(email).trim().toLowerCase());
    }

    if (!targetUser) {
      return res.status(404).json({
        error: 'Rider account not found for that email or user ID.',
        reason: 'USER_NOT_FOUND',
      });
    }

    if (targetUser.userId === uid) {
      return res.status(400).json({
        error: 'You are the membership owner and already have a seat.',
        reason: 'OWNER_CANNOT_INVITE_SELF',
      });
    }

    if (members[targetUser.userId]) {
      return res.status(409).json({
        error: 'This rider has already been added to your membership.',
        reason: 'ALREADY_MEMBER',
        member: members[targetUser.userId],
      });
    }

    members[targetUser.userId] = {
      userId: targetUser.userId,
      name: targetUser.name,
      email: targetUser.email,
      phone: targetUser.phone || '',
      status: 'INVITED',
      invitedAt: Date.now(),
    };

    membership.members = members;
    await repo.saveMembership(membership);

    res.json({
      message: `Invitation sent to ${targetUser.name}`,
      members: Object.values(members),
      capacity: membership.capacity,
      remainingSeats: membership.capacity - (1 + Object.keys(members).length),
    });
  }));

  /**
   * POST /api/membership/members/respond
   */
  r.post('/membership/members/respond', actionLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const { membershipId, action } = req.body || {};

    if (!membershipId || !['ACCEPT', 'DECLINE'].includes(action)) {
      return res.status(400).json({ error: 'membershipId and valid action (ACCEPT or DECLINE) are required.', reason: 'BAD_REQUEST' });
    }

    const membership = await repo.findMembershipById(membershipId);
    if (!membership || !membership.members || !membership.members[uid]) {
      return res.status(404).json({ error: 'No invitation found for your account in this membership.', reason: 'INVITATION_NOT_FOUND' });
    }

    if (action === 'ACCEPT') {
      membership.members[uid].status = 'ACCEPTED';
      membership.members[uid].acceptedAt = Date.now();
    } else {
      membership.members[uid].status = 'DECLINED';
      membership.members[uid].declinedAt = Date.now();
    }

    await repo.saveMembership(membership);

    res.json({
      message: action === 'ACCEPT' ? 'Membership invitation accepted' : 'Membership invitation declined',
      action,
      membershipId,
      ownerName: membership.ownerName,
    });
  }));

  /**
   * DELETE /api/membership/members/:targetUserId
   */
  r.delete('/membership/members/:targetUserId', actionLimiter, wrap(async (req, res) => {
    const uid = req.user.userId;
    const targetUserId = req.params.targetUserId;

    const membership = await repo.findMembershipByOwner(uid);
    if (!membership) {
      return res.status(403).json({ error: 'You do not own an active membership.', reason: 'NOT_OWNER' });
    }

    if (!membership.members || !membership.members[targetUserId]) {
      return res.status(404).json({ error: 'Member not found in your group membership.', reason: 'MEMBER_NOT_FOUND' });
    }

    delete membership.members[targetUserId];
    await repo.saveMembership(membership);

    // If removed member is in owner's active trip, remove them from that convoy
    const ownerActiveTrip = await repo.getActiveTrip(uid);
    if (ownerActiveTrip && convoys && typeof convoys.leaveConvoy === 'function') {
      try {
        await convoys.leaveConvoy(ownerActiveTrip.groupId, targetUserId, { reason: 'REMOVED_BY_MEMBERSHIP_OWNER' });
      } catch {
        // ignore
      }
    }

    res.json({
      message: 'Member removed successfully.',
      members: Object.values(membership.members),
      capacity: membership.capacity,
      remainingSeats: membership.capacity - (1 + Object.keys(membership.members).length),
    });
  }));

  // =========================================================================
  // 3. PLATFORM ADMIN ENDPOINTS
  // =========================================================================

  r.get('/admin/membership/catalog', requireAdmin, wrap(async (req, res) => {
    const catalog = await repo.getMembershipCatalog();
    res.json({ catalog });
  }));

  r.put('/admin/membership/catalog', requireAdmin, wrap(async (req, res) => {
    const { catalog } = req.body || {};
    if (!catalog || typeof catalog !== 'object') {
      return res.status(400).json({ error: 'Valid catalog object required.', reason: 'INVALID_CATALOG' });
    }
    await repo.setMembershipCatalog(catalog, req.user.email || req.user.userId);
    res.json({ message: 'Membership catalog updated successfully.', catalog });
  }));

  r.get('/admin/membership/analytics', requireAdmin, wrap(async (req, res) => {
    const allMemberships = await repo.soda.query(repo.soda.collections?.memberships || 'memberships', {}, { limit: 10000 });
    const now = Date.now();

    let individualActive = 0;
    let groupSmallActive = 0;
    let groupLargeActive = 0;
    let totalMRR = 0;
    let totalSeatsAllocated = 0;
    let totalSeatsOccupied = 0;

    for (const r of allMemberships) {
      const m = r.value;
      if (m.status === 'ACTIVE' && m.validUntil > now) {
        if (m.category === 'individual') {
          individualActive++;
          totalMRR += (m.priceInr || 9);
          totalSeatsAllocated += 1;
          totalSeatsOccupied += 1;
        } else if (m.category === 'group_small') {
          groupSmallActive++;
          totalMRR += (m.priceInr || 49);
          totalSeatsAllocated += (m.capacity || 6);
          totalSeatsOccupied += (1 + Object.keys(m.members || {}).length);
        } else if (m.category === 'group_large') {
          groupLargeActive++;
          totalMRR += (m.priceInr || 99);
          totalSeatsAllocated += (m.capacity || 12);
          totalSeatsOccupied += (1 + Object.keys(m.members || {}).length);
        }
      }
    }

    const activeTripsCount = await repo.soda.query(repo.soda.collections?.activeTrips || 'active_trips', {}, { limit: 10000 });

    res.json({
      activeMemberships: {
        individual: individualActive,
        groupSmall: groupSmallActive,
        groupLarge: groupLargeActive,
        total: individualActive + groupSmallActive + groupLargeActive,
      },
      seatUtilization: {
        totalAllocated: totalSeatsAllocated,
        totalOccupied: totalSeatsOccupied,
        utilizationRate: totalSeatsAllocated > 0 ? (totalSeatsOccupied / totalSeatsAllocated).toFixed(2) : 0,
      },
      financialMetrics: {
        estimatedMRR: totalMRR,
        currency: 'INR',
      },
      concurrency: {
        currentActiveTrips: activeTripsCount.length,
      },
      timestamp: now,
    });
  }));
}

module.exports = {
  registerMembershipPublicRoutes,
  registerMembershipAuthRoutes,
};
