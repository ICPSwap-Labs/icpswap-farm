import Text "mo:base/Text";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Int64 "mo:base/Int64";
import Time "mo:base/Time";
import Bool "mo:base/Bool";
import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Cycles "mo:base/ExperimentalCycles";
import SafeUint "mo:commons/math/SafeUint";
import Types "./Types";

shared (initMsg) actor class FarmFactoryValidator(
    farmFactoryCid : Principal,
    governanceCid : Principal,
) = this {

    public type Result = {
        #Ok : Text;
        #Err : Text;
    };

    private stable var _initCycles : Nat = 1860000000000;

    private stable var ONE_YEAR : Nat = 31557600;
    private stable var SIX_MONTH : Nat = 15778800;
    private stable var ONE_MONTH : Nat = 2629800;
    private stable var ONE_WEEK : Nat = 604800;
    private stable var TWELVE_HOURS : Nat = 43200;
    private stable var FOUR_HOURS : Nat = 14400;
    private stable var THIRTY_MINUTES : Nat = 1800;

    private var _farmFactoryAct = actor (Principal.toText(farmFactoryCid)) : Types.IFarmFactory;

    public shared (msg) func createValidate(args : Types.CreateFarmArgs) : async Result {
        assert (Principal.equal(msg.caller, governanceCid));

        var nowTime = _getTime();
        if (args.rewardAmount <= 0) {
            return #Err("Reward amount must be positive");
        };
        if (nowTime > args.startTime) {
            return #Err("Start time must be after current time");
        };
        if (args.startTime >= args.endTime) {
            return #Err("Start time must be before end time");
        };
        if ((SafeUint.Uint256(args.startTime).sub(SafeUint.Uint256(nowTime)).val()) > ONE_MONTH) {
            return #Err("Start time is too far from current time");
        };
        var duration = SafeUint.Uint256(args.endTime).sub(SafeUint.Uint256(args.startTime)).val();
        if (duration > ONE_YEAR) {
            return #Err("Incentive duration cannot be more than 1 year");
        } else if (duration > SIX_MONTH) {
            if (args.secondPerCycle < TWELVE_HOURS) {
                return #Err("The reward distribution cycle cannot be faster than 12 hours");
            };
        } else if (duration > ONE_MONTH) {
            if (args.secondPerCycle < FOUR_HOURS) {
                return #Err("The reward distribution cycle cannot be faster than 4 hours");
            };
        } else if (duration >= ONE_WEEK) {
            if (args.secondPerCycle < THIRTY_MINUTES) {
                return #Err("The reward distribution cycle cannot be faster than 30 minutes");
            };
        } else {
            return #Err("Incentive duration cannot be less than 1 week");
        };

        // check reward token
        let rewardPoolAct = actor (Principal.toText(args.rewardPool)) : actor {
            metadata : query () -> async Result.Result<Types.PoolMetadata, Types.Error>;
        };
        switch (await rewardPoolAct.metadata()) {
            case (#ok(poolMetadata)) {
                if (Text.notEqual(args.rewardToken.address, poolMetadata.token0.address) and Text.notEqual(args.rewardToken.address, poolMetadata.token1.address)) {
                    return #Err("Illegal SwapPool of reward token");
                };
            };
            case (#err(code)) {
                return #Err("Illegal SwapPool of reward token: " # debug_show (code));
            };
        };

        switch (await _farmFactoryAct.getCycleInfo()) {
            case (#ok(cycleInfo)) {
                if (cycleInfo.balance <= _initCycles or cycleInfo.available <= _initCycles) {
                    return #Err("Insufficient Cycle Balance.");
                };
            };
            case (#err(code)) {
                return #Err("Get cycle info of FarmFactory failed: " # debug_show (code));
            };
        };

        return #Ok(debug_show (args));
    };

    public shared (msg) func setAdminsValidate(admins : [Principal]) : async Result {
        assert (Principal.equal(msg.caller, governanceCid));
        return #Ok(debug_show (admins));
    };

    public shared ({ caller }) func setFarmAdminsValidate(farmCid : Principal, admins : [Principal]) : async Result {
        assert (Principal.equal(caller, governanceCid));
        if (not (await _checkFarm(farmCid))) {
            return #Err(Principal.toText(farmCid) # " doesn't exist.");
        };
        return #Ok(debug_show (farmCid) # ", " # debug_show (admins));
    };

    public shared ({ caller }) func addFarmControllersValidate(farmCid : Principal, controllers : [Principal]) : async Result {
        assert (Principal.equal(caller, governanceCid));
        if (not (await _checkFarm(farmCid))) {
            return #Err(Principal.toText(farmCid) # " doesn't exist.");
        };
        return #Ok(debug_show (farmCid) # ", " # debug_show (controllers));
    };

    public shared ({ caller }) func removeFarmControllersValidate(farmCid : Principal, controllers : [Principal]) : async Result {
        assert (Principal.equal(caller, governanceCid));
        if (not (await _checkFarm(farmCid))) {
            return #Err(Principal.toText(farmCid) # " doesn't exist.");
        };
        for (it in controllers.vals()) {
            if (Principal.equal(it, farmFactoryCid)) {
                return #Err("FarmFactory must be the controller of Farm.");
            };
        };
        return #Ok(debug_show (farmCid) # ", " # debug_show (controllers));
    };

    public query func getInitArgs() : async Result.Result<{ farmFactoryCid : Principal; governanceCid : Principal }, Types.Error> {
        #ok({
            farmFactoryCid = farmFactoryCid;
            governanceCid = governanceCid;
        });
    };

    public shared (msg) func getCycleInfo() : async Result.Result<Types.CycleInfo, Types.Error> {
        return #ok({
            balance = Cycles.balance();
            available = Cycles.available();
        });
    };

    // --------------------------- Version Control ------------------------------------
    private var _version : Text = "3.2.0";
    public query func getVersion() : async Text { _version };

    private func _getTime() : Nat {
        return Nat64.toNat(Int64.toNat64(Int64.fromInt(Time.now() / 1000000000)));
    };

    private func _checkFarm(farmCid : Principal) : async Bool {
        switch (await _farmFactoryAct.getAllFarms()) {
            case (#ok(farms)) {
                for (it in farms.vals()) {
                    if (Principal.equal(farmCid, it)) {
                        return true;
                    };
                };
                return false;
            };
            case (#err(msg)) {
                return false;
            };
        };
    };
};
