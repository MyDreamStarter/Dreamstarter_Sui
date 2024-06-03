module addrx::dreamstarter_collab {
    use std::string::{Self, String};
    use sui::object::{Self, ID, UID};
    use sui::event;
    use std::vector;
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::url::{Self, Url};
    use sui::clock::{Self, Clock};

    //==============================================================================================
    // Constants
    //==============================================================================================
    const NFT_DESC: vector<u8> = b"DreamStarter collab";

    //==============================================================================================
    // Error codes
    //==============================================================================================
    const EInsufficientFunds: u64 = 1;
    const ENotActiveProposal: u64 = 2;
    const ENotProposalCreator: u64 = 3;
    const ENotValidCall: u64 = 4;
    const EAlreadyFundingReached: u64 = 5;
    const ENotStaked: u64 = 6;
    const ENotUnpaused: u64 = 7;

    //==============================================================================================
    // Objects
    //==============================================================================================
    /// Capability that grants a fund owner the right to collect.
    struct AdminCap has key { id: UID }

    struct MileStoneInfo has key {
        id: UID,
        no_of_milestones_reached: u64,
        milestone_approved_funding: u64,
        next_expected_milestone_funding: u64,
        milestones: vector<String>,
    }

    struct State has key {
        id: UID,
        creator: address,
        pause: bool, // automatic
        is_creator_staked: bool, // automatic
        is_proposal_cleared: bool, // automatic
        is_proposal_rejected: bool, // automatic
        crowdfunding_goal: u64, // automatic
        funding_active_time: u64, // input
        funding_end_time: u64,
        saleprice: u64,
        stake: Balance<SUI>,
        funds_in_reserve: Balance<SUI>, // automatic
    }

    struct DreamStarterCollab_NFT has key, store {
        id: UID,
        name: String,
        description: String,
        url: Url,
        refund: bool,
    }

    //==============================================================================================
    // Event Structs
    //==============================================================================================
    struct NFTMintedEvent has copy, drop {
        object_id: ID,
        creator: address,
        name: String,
        url: Url
    }

    // Initialization function to create and transfer AdminCap to the caller
    entry fun init(ctx: &mut TxContext) {
        transfer::transfer(AdminCap {
            id: object::new(ctx)
        }, tx_context::sender(ctx));
    }

    // Function to initialize the crowdfunding state and milestone info
    entry fun initialize(
        target_amount: u64,
        end_time: u64,
        nft_price_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        transfer::share_object(State {
            id: object::new(ctx),
            creator: tx_context::sender(ctx),
            pause: true,
            is_creator_staked: false,
            is_proposal_cleared: false,
            is_proposal_rejected: false,
            crowdfunding_goal: target_amount,
            funding_active_time: clock::timestamp_ms(clock),
            funding_end_time: clock::timestamp_ms(clock) + end_time,
            saleprice: nft_price_amount,
            stake: balance::zero(),
            funds_in_reserve: balance::zero(),
        });

        transfer::share_object(MileStoneInfo {
            id: object::new(ctx),
            no_of_milestones_reached: 0,
            milestone_approved_funding: 0,
            next_expected_milestone_funding: 0,
            milestones: vector::empty<String>(),
        });
    }

    // Function to handle proposal rejection based on funding goal expiration and staking status
    entry fun initiate_proposal_rejection(state: &mut State, clock: &Clock) {
        assert_is_funding_goal_expired(state, clock);

        let funding_reached = balance::value(&state.funds_in_reserve);
        if funding_reached < state.crowdfunding_goal || !state.is_creator_staked {
            state.is_proposal_rejected = true;
            state.is_proposal_cleared = true;
        } else {
            abort(ENotValidCall);
        }
    }

    // Function for staking funds to the proposal
    public fun stake(amount: Coin<SUI>, state: &mut State, ctx: &TxContext) {
        assert_is_proposal_creator(state, tx_context::sender(ctx));
        let stake_amount = (state.crowdfunding_goal * 20) / 100;
        assert!(coin::value(&amount) >= stake_amount, EInsufficientFunds);
        let coin_balance = coin::into_balance(amount);
        balance::join(&mut state.stake, coin_balance);
        state.is_creator_staked = true;
    }

    // Function to mint an NFT and contribute funds to the proposal
    public entry fun mint_and_contribute(
        amount: Coin<SUI>,
        name: String,
        uri: String,
        clock: &Clock,
        state: &mut State,
        ctx: &mut TxContext
    ) {
        assert_is_funding_goal_expired(state, clock);
        let current_funds = balance::value(&state.funds_in_reserve);
        if state.crowdfunding_goal <= current_funds {
            abort(EAlreadyFundingReached);
        }

        let coin_value = coin::value(&amount);
        assert!(coin_value >= state.saleprice, EInsufficientFunds);
        let coin_balance = coin::into_balance(amount);
        balance::join(&mut state.funds_in_reserve, coin_balance);

        let nft = DreamStarterCollab_NFT {
            id: object::new(ctx),
            name,
            description: string::utf8(NFT_DESC),
            url: url::new_unsafe_from_bytes(*string::bytes(&uri)),
            refund: false,
        };

        event::emit(NFTMintedEvent {
            object_id: object::id(&nft),
            creator: tx_context::sender(ctx),
            name: nft.name,
            url: nft.url,
        });

        transfer::transfer(nft, tx_context::sender(ctx));
    }

    // Function to submit milestone information
    entry fun submit_milestone_info(
        next_amount: u64,
        audit_report: String,
        milestone: &mut MileStoneInfo
    ) {
        let length = vector::length(&milestone.milestones);
        assert!(milestone.next_expected_milestone_funding == 0 && length == milestone.no_of_milestones_reached, ENotValidCall);

        vector::push_back(&mut milestone.milestones, audit_report);
        milestone.next_expected_milestone_funding = next_amount;
    }

    // Function to validate the proposal
    entry fun validate(
        _: &AdminCap,
        result: bool,
        proposal_rejected_status: bool,
        state: &mut State
    ) {
        if result {
            let current_funds = balance::value(&state.funds_in_reserve);
            if current_funds == 0 {
                state.is_proposal_cleared = true;
            } else {
                unpause(state);
            }
        } else {
            if proposal_rejected_status {
                state.is_proposal_rejected = true;
            } else {
                pause(state);
            }
        }
    }

    // Function to withdraw funds from the proposal
    entry fun withdraw_funds(
        amount: u64,
        state: &mut State,
        clock: &Clock,
        milestones: &mut MileStoneInfo,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert_is_funding_goal_expired(state, clock);
        assert_is_proposal_creator(state, sender);
        assert!(state.is_creator_staked, ENotStaked);
        assert!(state.is_proposal_rejected == false && state.is_proposal_cleared == false, ENotValidCall);

        let current_funds = balance::value(&state.funds_in_reserve);
        assert!(state.crowdfunding_goal == current_funds, ENotValidCall);

        if milestones.no_of_milestones_reached == 0 {
            assert!(balance::value(&state.stake) >= amount, ENotValidCall);
            transfer_funds(amount, false, state, ctx);
            milestones.no_of_milestones_reached = 1;
            pause(state);
        } else {
            assert!(state.pause == false, ENotUnpaused);
            assert!(milestones.milestone_approved_funding >= amount, ENotValidCall);
            transfer_funds(amount, false, state, ctx);
            milestones.no_of_milestones_reached += 1;
            if balance::value(&state.funds_in_reserve) == 0 {
                state.is_proposal_cleared = true;
            } else {
                pause(state);
            }
        }
    }

    // Function to claim back funds if the proposal is rejected
    entry fun claimback(nft: &mut DreamStarterCollab_NFT, state: &mut State, ctx: &mut TxContext) {
        assert!(state.is_proposal_rejected && !nft.refund, ENotValidCall);
        nft.refund = true;
        transfer_funds(state.saleprice, false, state, ctx
    }

    // Function to unstake funds
    entry fun unstake(state: &mut State, ctx: &mut TxContext) {
        assert_is_proposal_creator(state, tx_context::sender(ctx));
        transfer_funds(balance::value(&state.stake), true, state, ctx);
    }

    // Function for the admin to withdraw funds
    entry fun admin_withdraw(
        _: &AdminCap,
        milestone: &MileStoneInfo,
        state: &mut State,
        ctx: &mut TxContext
    ) {
        assert!(state.is_proposal_rejected && milestone.no_of_milestones_reached != 0, ENotValidCall);
        transfer_funds(balance::value(&state.stake), true, state, ctx);
    }

    // Helper function to pause the proposal
    fun pause(state: &mut State) {
        state.pause = true;
    }

    // Helper function to unpause the proposal
    fun unpause(state: &mut State) {
        state.pause = false;
    }

    // Function to transfer funds
    entry fun transfer_funds(amount: u64, is_stake_amount: bool, state: &mut State, ctx: &mut TxContext) {
        if is_stake_amount {
            amount = balance::value(&state.stake);
        }
        let withdraw_obj = coin::take(&mut state.funds_in_reserve, amount, ctx);
        transfer::public_transfer(withdraw_obj, tx_context::sender(ctx));
    }

    // Helper function to check if funding goal has expired
    fun assert_is_funding_goal_expired(state: &State, clock: &Clock) {
        let current_time = clock::timestamp_ms(clock);
        assert!(state.funding_end_time < current_time, ENotActiveProposal);
    }

    // Helper function to check if the user is the proposal creator
    fun assert_is_proposal_creator(state: &State, user: address) {
        assert!(state.creator == user, ENotProposalCreator);
    }
}
