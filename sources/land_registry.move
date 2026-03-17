module land_registry::land_registry {
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::clock::{Self, Clock};
    use sui::event;
    use std::string::{Self, String};
    use std::option::{Self, Option};


    const SIX_MONTHS_MS: u64 = 15_552_000_000;

    const STATUS_PENDING: u8   = 0;
    const STATUS_DISPUTED: u8  = 1;
    const STATUS_COMPLETED: u8 = 2;
    const STATUS_CANCELLED: u8 = 3;

    const ENotOwner: u64              = 1;
    const ELandLocked: u64            = 2;
    const ETooEarly: u64              = 3;
    const EAlreadyDisputed: u64       = 4;
    const ENotPending: u64            = 5;
    const EWrongPlot: u64             = 6;
    const ENotDisputed: u64           = 7;
    const EComplaintWindowClosed: u64 = 8;
    const EBadgeIssuedAfterTransfer: u64 = 9;
    const EActiveBadgeExist: u64 = 10;

    const CLAIM_NEIGHBOR: u8 = 0;
    const CLAIM_HEIR: u8 = 1;
    const CLAIM_LIEN_HOLDER: u8 = 2;
    const CLAIM_GOVERNMENT: u8 = 3;

    public struct AdminCap has key, store {
        id: UID,
    }

    public struct LandNFT has key, store {
        id: UID,
        plot_id: String,
        location: String,
        gps_coords: String,
        size_sqm: u64,
        has_active_badge: bool,
        is_locked: bool,
    }

    public struct TransferRequest has key, store {
        id: UID,
        land_id: ID,
        from: address,
        to: address,
        initiated_at: u64,
        status: u8,
        complaint_text: Option<String>,
        complainant: Option<address>,
        land: LandNFT,
    }

    public struct ClaimantBadge has key, store {
        id: UID,
        owner: address,
        issued_by: address,
        issued_at: u64,
        claim_type: u8,
        plot_id: String,
    }

    

    public struct LandMinted has , drop {
        land_id: ID,
        plot_id: String,
        recipient: address,
    }


    public struct ClaimantVerified has  drop {
        badge_id: ID,
        recipient: address,
        plot_id: String,
    }

    public struct TransferInitiated has , drop {
        request_id: ID,
        land_id: ID,
        from: address,
        to: address,
        initiated_at: u64,
    }

    public struct ComplaintFiled has , drop {
        request_id: ID,
        complainant: address,
        complaint_text: String,
        claim_type: u8,
    }

    public struct TransferCompleted has , drop {
        request_id: ID,
        land_id: ID,
        from: address,
        to: address,
    }

    public struct TransferCancelled has , drop {
        request_id: ID,
        land_id: ID,
        returned_to: address,
    }
    fun init(ctx: &mut TxContext) {
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };  
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    public fun mint_land(
        _cap: &AdminCap,
        plot_id: vector<u8>,
        location: vector<u8>,
        gps_coords: vector<u8>,
        size_sqm: u64,
        recipient: address,
        ctx: &mut TxContext
    ) {
        let land = LandNFT {
            id: object::new(ctx),
            plot_id: string::utf8(plot_id),
            location: string::utf8(location),
            gps_coords: string::utf8(gps_coords),
            size_sqm,
            is_locked: false,
        };

        event::emit(LandMinted {
            land_id: object::id(&land),
            plot_id: land.plot_id,
            recipient,
        });

        transfer::transfer(land, recipient);
    }

    public fun admin_clear_badge(
        _cap: &AdminCap,
        land: &mut LandNFT,
        ctx: &mut TxContext,
    ) {
        land.has_active_badge = false;

        event::emit(BadgeCleared {
            land_id: object::id(land),
            plot_id: land.plot_id,
            cleared_by: tx_context::sender(ctx),
        });
    }

    public fun mint_admin_cap(
        _cap: &AdminCap,
        recipient: address,
        ctx: &mut TxContext
    ) {
        let new_cap = AdminCap {
            id: object::new(ctx),
        };
        transfer::transfer(new_cap, recipient);
    }

    public fun issue_claimant_badge(
        _cap: &AdminCap,
        recipient: address,
        clock: &Clock,
        claim_type: u8,
        land: &mut LandNFT,
        plot_id: vector<u8>,
        ctx: &mut TxContext
        issued_at: clock::timestamp_ms(clock),
        claim_type: u8,
        land.has_active_badge = true;
    ) {
        let badge = ClaimantBadge {
            id: object::new(ctx),
            owner: recipient,
            issued_by: tx_context::sender(ctx),
            plot_id: string::utf8(plot_id),
        };

        event::emit(ClaimantVerified {
            badge_id: object::id(&badge),
            recipient,
            plot_id: badge.plot_id,
        });

        transfer::transfer(badge, recipient);
    }

    

    public fun initiate_transfer(
        land: LandNFT,
        to: address,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(!land.is_locked, ELandLocked);
        assert!(!land.has_active_badge, EActiveBadgeExist);

        let from = tx_context::sender(ctx);
        let now = clock::timestamp_ms(clock);
        let land_id = object::id(&land);
        let plot_id = land.plot_id;

        let mut land_mut = land;
        land_mut.is_locked = true;

        let request = TransferRequest {
            id: object::new(ctx),
            land_id,
            from,
            to,
            initiated_at: now,
            status: STATUS_PENDING,
            complaint_text: option::none(),
            complainant: option::none(),
            land: land_mut,
        };

        event::emit(TransferInitiated {
            request_id: object::id(&request),
            land_id,
            from,
            to,
            initiated_at: now,
        });

        transfer::share_object(request);
    }

    public fun file_complaint(
        request: &mut TransferRequest,
        badge: &ClaimantBadge,
        complaint_text: vector<u8>,
        clock: &Clock,
        badge: ClaimantBadge,
        ctx: &mut TxContext
    ) {
        assert!(request.status == STATUS_PENDING, ENotPending);
        assert!(badge.plot_id == request.land.plot_id, EWrongPlot);
        assert!(badge.issued_at < request.initiated_at, EBadgeIssuedAfterTransfer);

        let now = clock::timestamp_ms(clock);
        assert!(
            now < request.initiated_at + SIX_MONTHS_MS,
            EComplaintWindowClosed
        );

        let text = string::utf8(complaint_text);

        request.status = STATUS_DISPUTED;
        request.complaint_text = option::some(text);
        request.complainant = option::some(tx_context::sender(ctx));

        event::emit(ComplaintFiled {
            request_id: object::id(request),
            complainant: tx_context::sender(ctx),
            complaint_text: text,
            claim_type,
        });
    }

    public fun complete_transfer(
        request: TransferRequest,
        clock: &Clock,
        _ctx: &mut TxContext
    ) {
        assert!(request.status == STATUS_PENDING, ENotPending);

        let now = clock::timestamp_ms(clock);
        assert!(
            now >= request.initiated_at + SIX_MONTHS_MS,
            ETooEarly
        );

        let TransferRequest {
            id,
            land_id: _,
            from,
            to,
            initiated_at: _,
            status: _,
            complaint_text: _,
            complainant: _,
            mut land,
        } = request;

        land.is_locked = false;

        event::emit(TransferCompleted {
            request_id: object::uid_to_inner(&id),
            land_id: object::id(&land),
            from,
            to,
        });

        object::delete(id);
        transfer::transfer(land, to);
    }

    public fun cancel_transfer_as_seller(
        request: TransferRequest,
        ctx: &mut TxContext
    ) {
        assert!(request.status == STATUS_PENDING, ENotPending);
        assert!(request.from == tx_context::sender(ctx), ENotOwner);

        let TransferRequest {
            id,
            land_id: _,
            from,
            to: _,
            initiated_at: _,
            status: _,
            complaint_text: _,
            complainant: _,
            mut land,
        } = request;

        land.is_locked = false;

        event::emit(TransferCancelled {
            request_id: object::uid_to_inner(&id),
            land_id: object::id(&land),
            returned_to: from,
        });

        object::delete(id);
        transfer::transfer(land, from);
    }

    public fun admin_resolve_dispute(
        _cap: &AdminCap,
        request: TransferRequest,
        approve: bool,
        _ctx: &mut TxContext
    ) {
        assert!(request.status == STATUS_DISPUTED, ENotDisputed);

        let TransferRequest {
            id,
            land_id: _,
            from,
            to,
            initiated_at: _,
            status: _,
            complaint_text: _,
            complainant: _,
            mut land,
        } = request;

        land.is_locked = false;

        if (approve) {
            event::emit(TransferCompleted {
                request_id: object::uid_to_inner(&id),
                land_id: object::id(&land),
                from,
                to,
            });
            object::delete(id);
            transfer::transfer(land, to);
        } else {
            event::emit(TransferCancelled {
                request_id: object::uid_to_inner(&id),
                land_id: object::id(&land),
                returned_to: from,
            });
            object::delete(id);
            transfer::transfer(land, from);
        }
    }
}
