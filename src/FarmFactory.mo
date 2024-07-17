import Buffer "mo:base/Buffer";
import Cycles "mo:base/ExperimentalCycles";
import Error "mo:base/Error";
import List "mo:base/List";
import Time "mo:base/Time";
import Nat "mo:base/Nat";            
import Nat64 "mo:base/Nat64";
import Int64 "mo:base/Int64"; 
import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Text "mo:base/Text";
import CollectionUtils "mo:commons/utils/CollectionUtils";
import IC0Utils "mo:commons/utils/IC0Utils";
import SafeUint "mo:commons/math/SafeUint";
import Farm "./Farm";
import Types "./Types";
import Prim "mo:⛔";

shared (initMsg) actor class FarmFactory(
    feeReceiverCid : Principal,
    governanceCid : ?Principal,
    farmIndexCid : Principal,
    nodeIndexCid : Principal,
) = this {

    private stable var _initCycles : Nat = 1860000000000;

    private stable var ONE_YEAR : Nat = 31557600;
    private stable var SIX_MONTH : Nat = 15778800;
    private stable var ONE_MONTH : Nat = 2629800;
    private stable var ONE_WEEK : Nat = 604800;
    private stable var TWELVE_HOURS : Nat = 43200;
    private stable var FOUR_HOURS : Nat = 14400;
    private stable var THIRTY_MINUTES : Nat = 1800;

    private stable var _farms : [Principal] = [];

    private let IC0 = actor "aaaaa-aa" : actor {
        canister_status : { canister_id : Principal } -> async { settings : { controllers : [Principal] }; };
        update_settings : { canister_id : Principal; settings : { controllers : [Principal]; } } -> ();
    };
    private let _farmIndexAct = actor (Principal.toText(farmIndexCid)) : actor {
        updatePrincipalRecord : shared (principalRecord : [Principal]) -> async ();
        addFarmIndex : shared (input : Types.AddFarmIndexArgs) -> async ();
    };

    // the fee that is taken from every unstake that is executed on the farm in 1 per thousand
    private stable var _fee : Nat = 50;

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
        } else if (duration > SIX_MONTH) {
            if (args.secondPerCycle < TWELVE_HOURS) {
                return #err("The reward distribution cycle cannot be faster than 12 hours");
            };
        } else if (duration > ONE_MONTH) {
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
            let positionPoolAct = actor (Principal.toText(args.pool)) : actor {
                metadata : query () -> async Result.Result<Types.PoolMetadata, Types.Error>;
            };
            let positionPoolMetadata = switch (await positionPoolAct.metadata()) {
                case (#ok(metadata)) { metadata; };
                case (#err(code)) { throw Error.reject("Illegal position SwapPool: " # debug_show (code)); };
            };

            Cycles.add<system>(_initCycles);
            var farm = Principal.fromActor(await Farm.Farm({ rewardToken = args.rewardToken; pool = args.pool; startTime = args.startTime; endTime = args.endTime; refunder = args.refunder; totalReward = args.rewardAmount; status = #NOT_STARTED; secondPerCycle = args.secondPerCycle; token0AmountLimit = args.token0AmountLimit; token1AmountLimit = args.token1AmountLimit; priceInsideLimit = args.priceInsideLimit; creator = msg.caller; farmFactoryCid = Principal.fromActor(this); feeReceiverCid = feeReceiverCid; fee = _fee; governanceCid = governanceCid; farmIndexCid = farmIndexCid; nodeIndexCid = nodeIndexCid;}));
            await IC0Utils.update_settings_add_controller(farm, initMsg.caller);
            let farmActor = actor (Principal.toText(farm)) : Types.IFarm;
            await farmActor.init();
            // update farm index
            await _farmIndexAct.addFarmIndex({
                farmCid = farm;
                poolCid = args.pool;
                poolToken0 = positionPoolMetadata.token0;
                poolToken1 = positionPoolMetadata.token1;
                rewardToken = args.rewardToken;
                totalReward = args.rewardAmount;
            });

            var tempFarmIds = Buffer.Buffer<Principal>(0);
            for (z in _farms.vals()) { tempFarmIds.add(z) };
            tempFarmIds.add(farm);
            _farms := Buffer.toArray(tempFarmIds);

            _unlock();
            return #ok(Principal.toText(farm));
        } catch (error) {
            _unlock();
            return #err(Error.message(error));
        };
    };

    public shared func getCycleInfo() : async Result.Result<Types.CycleInfo, Types.Error> {
        return #ok({
            balance = Cycles.balance();
            available = Cycles.available();
        });
    };

    public shared (msg) func setFee(fee : Nat) : async () {
        _checkAdminPermission(msg.caller);
        _fee := fee;
    };

    public query func getFee() : async Result.Result<Nat, Types.Error> {
        return #ok(_fee);
    };

    public query func getInitArgs() : async Result.Result<{ 
        feeReceiverCid : Principal; 
        governanceCid : ?Principal;
        farmIndexCid : Principal;
    }, Types.Error> {
        #ok({
            feeReceiverCid = feeReceiverCid;
            governanceCid = governanceCid;
            farmIndexCid = farmIndexCid;
        });
    };

     public query func getAllFarms() : async Result.Result<[Principal], Types.Error> {
        return #ok(_farms);
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
    public shared (msg) func setFarmAdmins(farmCid : Principal, admins : [Principal]) : async () {
        _checkPermission(msg.caller);
        var farmAct = actor (Principal.toText(farmCid)) : Types.IFarm;
        await farmAct.setAdmins(admins);
    };

    public shared (msg) func addFarmControllers(farmCid : Principal, controllers : [Principal]) : async () {
        _checkPermission(msg.caller);
        let { settings } = await IC0.canister_status({ canister_id = farmCid });
        var controllerList = List.append(List.fromArray(settings.controllers), List.fromArray(controllers));
        IC0.update_settings({ canister_id = farmCid; settings = { controllers = List.toArray(controllerList) }; });
    };

    public shared (msg) func removeFarmControllers(farmCid : Principal, controllers : [Principal]) : async () {
        _checkPermission(msg.caller);
        if (not _checkFarmControllers(controllers)){
            throw Error.reject("FarmController must be the controller of Farm.");
        };
        let { settings } = await IC0.canister_status({ canister_id = farmCid });
        let buffer: Buffer.Buffer<Principal> = Buffer.Buffer<Principal>(0);
        for (it in settings.controllers.vals()) {
            if (not CollectionUtils.arrayContains<Principal>(controllers, it, Principal.equal)) {
                buffer.add(it);
            };
        };
        IC0.update_settings({ canister_id = farmCid; settings = { controllers = Buffer.toArray<Principal>(buffer) }; });
    };

    private func _checkFarmControllers(controllers : [Principal]) : Bool {
        let controllerCid : Principal = Principal.fromActor(this);
        for (it in controllers.vals()) {
            if (Principal.equal(it, controllerCid)) {
                return false;
            };
        };
        true;
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
    private var _version : Text = "3.2.0";
    public query func getVersion() : async Text { _version };

    // --------------------------- LIFE CYCLE -----------------------------------
    system func preupgrade() {};
    system func postupgrade() {};

    system func inspect({
        arg : Blob;
        caller : Principal;
        msg : Types.FarmFactoryMsg;
    }) : Bool {
        return switch (msg) {
            // Controller
            case (#setAdmins args)              { _hasPermission(caller) };
            case (#addFarmControllers args)     { _hasPermission(caller) };
            case (#removeFarmControllers args)  { _hasPermission(caller) };
            case (#setFarmAdmins args)          { _hasPermission(caller) };
            // Admin
            case (#create args)                 { _hasAdminPermission(caller) };
            case (#setFee args)                 { _hasAdminPermission(caller) };
            // Anyone
            case (_)                            { true };
        };
    };

};
