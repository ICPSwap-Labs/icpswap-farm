import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Int64 "mo:base/Int64";
import Time "mo:base/Time";
import Error "mo:base/Error";
import Bool "mo:base/Bool";
import Principal "mo:base/Principal";
import Result "mo:base/Result";
import SafeUint "mo:commons/math/SafeUint";
import Types "./Types";

shared (initMsg) actor class FarmControllerValidator(
    farmControllerCid : Principal,
    governanceCid : Principal,
    ICP : Types.Token,
) = this {

    private stable var _initCycles : Nat = 1860000000000;

    private stable var ONE_YEAR : Nat = 31557600;
    private stable var SIX_MONTH : Nat = 15778800;
    private stable var ONE_MONTH : Nat = 2629800;
    private stable var ONE_WEEK : Nat = 604800;
    private stable var TWELVE_HOURS : Nat = 43200;
    private stable var FOUR_HOURS : Nat = 14400;
    private stable var THIRTY_MINUTES : Nat = 1800;

    private var _farmControllerAct = actor (Principal.toText(farmControllerCid)) : Types.IFarmController;

    public shared (msg) func setAdminsValidate(admins : [Principal]) : async Result.Result<Text, Text> {
        assert (Principal.equal(msg.caller, governanceCid));
        return #ok("admins: " # debug_show (admins));
    };

    public shared (msg) func createValidate(args : Types.CreateFarmArgs) : async Result.Result<Text, Text> {
        assert (Principal.equal(msg.caller, governanceCid));

        var nowTime = _getTime();
        if (args.rewardAmount <= 0) {
            return #err("Reward amount must be positive");
        };
        if (nowTime > args.startTime) {
            return #err("Start time must be after current time");
        };
        if (args.startTime >= args.endTime) {
            return #err("Start time must be before end time");
        };
        if ((SafeUint.Uint256(args.startTime).sub(SafeUint.Uint256(nowTime)).val()) > ONE_MONTH) {
            return #err("Start time is too far from current time");
        };
        var duration = SafeUint.Uint256(args.endTime).sub(SafeUint.Uint256(args.startTime)).val();
        if (duration > ONE_YEAR) {
            return #err("Incentive duration cannot be more than 1 year");
        } else if (duration >= SIX_MONTH) {
            if (args.secondPerCycle < TWELVE_HOURS) {
                return #err("The reward distribution cycle cannot be faster than 12 hours");
            };
        } else if (duration >= ONE_MONTH) {
            if (args.secondPerCycle < FOUR_HOURS) {
                return #err("The reward distribution cycle cannot be faster than 4 hours");
            };
        } else if (duration >= ONE_WEEK) {
            if (args.secondPerCycle < THIRTY_MINUTES) {
                return #err("The reward distribution cycle cannot be faster than 30 minutes");
            };
        } else {
            return #err("Incentive duration cannot be less than 1 week");
        };

        // check reward token
        let rewardPoolAct = actor (Principal.toText(args.rewardPool)) : actor {
            metadata : query () -> async Result.Result<Types.PoolMetadata, Types.Error>;
        };
        switch (await rewardPoolAct.metadata()) {
            case (#ok(poolMetadata)) {
                if (
                    (Text.notEqual(args.rewardToken.address, poolMetadata.token0.address) and Text.notEqual(args.rewardToken.address, poolMetadata.token1.address)) or
                    (Text.notEqual(ICP.address, poolMetadata.token0.address) and Text.notEqual(ICP.address, poolMetadata.token1.address))
                ) {
                    throw Error.reject("Illegal SwapPool of reward token");
                };
            };
            case (#err(code)) {
                throw Error.reject("Illegal SwapPool of reward token: " # debug_show (code));
            };
        };

        switch (await _farmControllerAct.getCycleInfo()) {
            case (#ok(cycleInfo)) {
                if (cycleInfo.balance <= _initCycles or cycleInfo.available <= _initCycles) {
                    throw Error.reject("Insufficient Cycle Balance.");
                };
            };
            case (#err(code)) {
                throw Error.reject("Get cycle info of FarmController failed: " # debug_show (code));
            };
        };

        return #ok("args: " # debug_show (args));
    };

    private func _getTime() : Nat {
        return Nat64.toNat(Int64.toNat64(Int64.fromInt(Time.now() / 1000000000)));
    };
};
