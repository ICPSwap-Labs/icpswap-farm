import Array "mo:base/Array";
import Buffer "mo:base/Buffer";
import Debug "mo:base/Debug";
import Cycles "mo:base/ExperimentalCycles";
import Error "mo:base/Error";
import Float "mo:base/Float";
import HashMap "mo:base/HashMap";
import Int "mo:base/Int";
import List "mo:base/List";
import Time "mo:base/Time";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import Int64 "mo:base/Int64";
import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Text "mo:base/Text";
import Iter "mo:base/Iter";
import CollectionUtils "mo:commons/utils/CollectionUtils";
import IC0Utils "mo:commons/utils/IC0Utils";
import SafeUint "mo:commons/math/SafeUint";
import SafeInt "mo:commons/math/SafeInt";
import Farm "./Farm";
import Types "./Types";
import Prim "mo:⛔";
import FarmDataService "./components/FarmData";

shared (initMsg) actor class FarmController(
    ICP : Types.Token,
    feeReceiverCid : Principal,
    governanceCid : ?Principal,
) = this {

    private stable var _initCycles : Nat = 1860000000000;

    private stable var ONE_YEAR : Nat = 31557600;
    private stable var SIX_MONTH : Nat = 15778800;
    private stable var ONE_MONTH : Nat = 2629800;
    private stable var ONE_WEEK : Nat = 604800;
    private stable var TWELVE_HOURS : Nat = 43200;
    private stable var FOUR_HOURS : Nat = 14400;
    private stable var THIRTY_MINUTES : Nat = 1800;

    // the fee that is taken from every unstake that is executed on the farm in 1 per thousand
    private stable var _fee : Nat = 50;

    private stable var _farmDataState : FarmDataService.State = {
        notStartedFarmEntries = [];
        liveFarmEntries = [];
        finishedFarmEntries = [];
        closedFarmEntries = [];
    };
    private var _farmDataService : FarmDataService.Service = FarmDataService.Service(_farmDataState);

    public shared (msg) func create(args : Types.CreateFarmArgs) : async Result.Result<Text, Text> {
        _checkAdminPermission(msg.caller);

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

        if (not _lock()) {
            return #err("Please wait for the task ahead to be completed");
        };

        try {
            // check reward token
            let rewardPoolAct = actor (Principal.toText(args.rewardPool)) : actor {
                metadata : query () -> async Result.Result<Types.PoolMetadata, Types.Error>;
            };
            let rewardPoolMetadata = switch (await rewardPoolAct.metadata()) {
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

            Cycles.add(_initCycles);
            var farm = Principal.fromActor(await Farm.Farm({ ICP = ICP; rewardToken = args.rewardToken; pool = args.pool; rewardPool = args.rewardPool; startTime = args.startTime; endTime = args.endTime; refunder = args.refunder; totalReward = args.rewardAmount; status = #NOT_STARTED; secondPerCycle = args.secondPerCycle; token0AmountLimit = args.token0AmountLimit; token1AmountLimit = args.token1AmountLimit; priceInsideLimit = args.priceInsideLimit; creator = msg.caller; farmControllerCid = Principal.fromActor(this); feeReceiverCid = feeReceiverCid; fee = _fee }));
            await IC0Utils.update_settings_add_controller(farm, initMsg.caller);
            let farmActor = actor (Principal.toText(farm)) : Types.IFarm;
            await farmActor.init();

            _farmDataService.putNotStartedFarm(
                farm,
                {
                    stakedTokenTVL = 0;
                    rewardTokenTVL = 0;
                },
            );

            _unlock();
            return #ok(Principal.toText(farm));
        } catch (error) {
            _unlock();
            return #err(Error.message(error));
        };
    };

    public shared (msg) func updateFarmInfo(status : Types.FarmStatus, tvl : Types.TVL) : async () {
        _farmDataService.deleteNotStartedFarm(msg.caller);
        _farmDataService.deleteLiveFarm(msg.caller);
        _farmDataService.deleteFinishedFarm(msg.caller);
        _farmDataService.deleteClosedFarm(msg.caller);
        if (status == #NOT_STARTED) {
            _farmDataService.putNotStartedFarm(msg.caller, tvl);
        } else if (status == #LIVE) {
            _farmDataService.putLiveFarm(msg.caller, tvl);
        } else if (status == #FINISHED) {
            _farmDataService.putFinishedFarm(msg.caller, tvl);
        } else if (status == #CLOSED) {
            _farmDataService.putClosedFarm(msg.caller, tvl);
        };
    };

    public shared (msg) func getCycleInfo() : async Result.Result<Types.CycleInfo, Types.Error> {
        return #ok({
            balance = Cycles.balance();
            available = Cycles.available();
        });
    };

    public query func getFarms(status : ?Types.FarmStatus) : async Result.Result<[(Principal, Types.TVL)], Text> {
        switch (status) {
            case (? #NOT_STARTED) {
                return #ok(_farmDataService.getTargetArray(#NOT_STARTED));
            };
            case (? #LIVE) {
                return #ok(_farmDataService.getTargetArray(#LIVE));
            };
            case (? #FINISHED) {
                return #ok(_farmDataService.getTargetArray(#FINISHED));
            };
            case (? #CLOSED) {
                return #ok(_farmDataService.getTargetArray(#CLOSED));
            };
            case (null) { return #ok(_farmDataService.getAllArray()) };
        };
    };

    public query func getAllFarms() : async Result.Result<{ NOT_STARTED : [(Principal, Types.TVL)]; LIVE : [(Principal, Types.TVL)]; FINISHED : [(Principal, Types.TVL)]; CLOSED : [(Principal, Types.TVL)] }, Text> {
        return #ok({
            NOT_STARTED = _farmDataService.getTargetArray(#NOT_STARTED);
            LIVE = _farmDataService.getTargetArray(#LIVE);
            FINISHED = _farmDataService.getTargetArray(#FINISHED);
            CLOSED = _farmDataService.getTargetArray(#CLOSED);
        });
    };

    public query func getInitArgs() : async Result.Result<{ ICP : Types.Token; feeReceiverCid : Principal; governanceCid : ?Principal }, Types.Error> {
        #ok({
            ICP = ICP;
            feeReceiverCid = feeReceiverCid;
            governanceCid = governanceCid;
        });
    };

    public query func getGlobalTVL() : async Result.Result<Types.TVL, Types.Error> {
        var stakedTokenTVL : Float = 0;
        var rewardTokenTVL : Float = 0;
        var targetArray = _farmDataService.getAllArray();
        for ((farmCid, farmInfo) in targetArray.vals()) {
            stakedTokenTVL := Float.add(stakedTokenTVL, farmInfo.stakedTokenTVL);
            rewardTokenTVL := Float.add(rewardTokenTVL, farmInfo.rewardTokenTVL);
        };
        return #ok({
            stakedTokenTVL = stakedTokenTVL;
            rewardTokenTVL = rewardTokenTVL;
        });
    };

    private func _getTime() : Nat {
        return Nat64.toNat(Int64.toNat64(Int64.fromInt(Time.now() / 1000000000)));
    };

    // --------------------------- LOCK ------------------------------------
    private stable var _lockState : Types.LockState = {
        locked = false;
        time = 0;
    };
    private func _lock() : Bool {
        let now = Time.now();
        if ((not _lockState.locked) or ((now - _lockState.time) > 1000000000 * 60)) {
            _lockState := { locked = true; time = now };
            return true;
        };
        return false;
    };
    private func _unlock() {
        _lockState := { locked = false; time = 0 };
    };

    // --------------------------- ACL ------------------------------------
    private stable var _admins : [Principal] = [initMsg.caller];
    public shared (msg) func setAdmins(admins : [Principal]) : async () {
        _checkPermission(msg.caller);
        _admins := admins;
    };
    public query func getAdmins() : async Result.Result<[Principal], Types.Error> {
        return #ok(_admins);
    };
    private func _checkAdminPermission(caller : Principal) {
        assert (_hasAdminPermission(caller));
    };

    private func _hasAdminPermission(caller : Principal) : Bool {
        return (CollectionUtils.arrayContains<Principal>(_admins, caller, Principal.equal) or _hasPermission(caller));
    };

    private func _checkPermission(caller : Principal) {
        assert (_hasPermission(caller));
    };

    private func _hasPermission(caller : Principal) : Bool {
        return Prim.isController(caller) or (switch (governanceCid) { case (?cid) { Principal.equal(caller, cid) }; case (_) { false } });
    };

    // --------------------------- Version Control ------------------------------------
    private var _version : Text = "3.0.0";
    public query func getVersion() : async Text { _version };

    // --------------------------- LIFE CYCLE -----------------------------------
    system func preupgrade() {
        _farmDataState := _farmDataService.getState();
    };
    system func postupgrade() {};

    system func inspect({
        arg : Blob;
        caller : Principal;
        msg : Types.FarmControllerMsg;
    }) : Bool {
        return switch (msg) {
            // Controller
            case (#setAdmins args) { _hasPermission(caller) };
            // Admin
            case (#create args) { _hasAdminPermission(caller) };
            // Anyone
            case (_) { true };
        };
    };

};
