import Buffer "mo:base/Buffer";
import Cycles "mo:base/ExperimentalCycles";
import Time "mo:base/Time";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import TrieSet "mo:base/TrieSet";
import Iter "mo:base/Iter";
import Int64 "mo:base/Int64";
import Principal "mo:base/Principal";
import Option "mo:base/Option";
import Result "mo:base/Result";
import Text "mo:base/Text";
import HashMap "mo:base/HashMap";
import CollectionUtils "mo:commons/utils/CollectionUtils";
import Types "./Types";
import Prim "mo:⛔";

shared (initMsg) actor class FarmIndex(
    factoryCid : Principal
) = this {

    private stable var _farms : [Principal] = [];
    private stable var _principalRecordSet = TrieSet.empty<Principal>();

    private stable var _notStartedFarmSet = TrieSet.empty<Principal>();
    private stable var _liveFarmSet = TrieSet.empty<Principal>();
    private stable var _finishedFarmSet = TrieSet.empty<Principal>();
    private stable var _closedFarmSet = TrieSet.empty<Principal>();

    private stable var _farmRewardInfoEntries : [(Principal, Types.FarmRewardInfo)] = [];
    private var _farmRewardInfos : HashMap.HashMap<Principal, Types.FarmRewardInfo> = HashMap.fromIter<Principal, Types.FarmRewardInfo>(_farmRewardInfoEntries.vals(), 0, Principal.equal, Principal.hash);

    private stable var _userFarmEntries : [(Principal, [Principal])] = [];
    private var _userFarms : HashMap.HashMap<Principal, [Principal]> = HashMap.fromIter<Principal, [Principal]>(_userFarmEntries.vals(), 0, Principal.equal, Principal.hash);

    private stable var _farmUserEntries : [(Principal, [Principal])] = [];
    private var _farmUsers : HashMap.HashMap<Principal, [Principal]> = HashMap.fromIter<Principal, [Principal]>(_farmUserEntries.vals(), 0, Principal.equal, Principal.hash);

    private stable var _poolKeyFarmEntries : [(Text, [Principal])] = [];
    private var _poolKeyFarms : HashMap.HashMap<Text, [Principal]> = HashMap.fromIter<Text, [Principal]>(_poolKeyFarmEntries.vals(), 0, Text.equal, Text.hash);

    private stable var _rewardTokenFarmEntries : [(Principal, [Principal])] = [];
    private var _rewardTokenFarms : HashMap.HashMap<Principal, [Principal]> = HashMap.fromIter<Principal, [Principal]>(_rewardTokenFarmEntries.vals(), 0, Principal.equal, Principal.hash);

    private var _factoryAct = actor (Principal.toText(factoryCid)) : Types.IFarmFactory;

    public shared (msg) func updateUserInfo(users : [Principal]) : async () {
        if (not CollectionUtils.arrayContains(_farms, msg.caller, Principal.equal)) {
            return;
        };
        for (user in users.vals()) {
            var tempFarmIds = TrieSet.empty<Principal>();
            var currentFarmIdList = switch (_userFarms.get(user)) { case (?list) { list }; case (_) { [] }; };
            for (z in currentFarmIdList.vals()) {
                tempFarmIds := TrieSet.put<Principal>(tempFarmIds, z, Principal.hash(z), Principal.equal);
            };
            tempFarmIds := TrieSet.put<Principal>(tempFarmIds, msg.caller, Principal.hash(msg.caller), Principal.equal);
            _userFarms.put(user, TrieSet.toArray(tempFarmIds));

            _principalRecordSet := TrieSet.put<Principal>(_principalRecordSet, user, Principal.hash(user), Principal.equal);
        };
        _farmUsers.put(msg.caller, users);
    };

    public shared (msg) func updateFarmStatus(status : Types.FarmStatus) : async () {
        if (not CollectionUtils.arrayContains(_farms, msg.caller, Principal.equal)) {
            return;
        };

        _notStartedFarmSet := TrieSet.delete<Principal>(_notStartedFarmSet, msg.caller, Principal.hash(msg.caller), Principal.equal);
        _liveFarmSet := TrieSet.delete<Principal>(_liveFarmSet, msg.caller, Principal.hash(msg.caller), Principal.equal);
        _finishedFarmSet := TrieSet.delete<Principal>(_finishedFarmSet, msg.caller, Principal.hash(msg.caller), Principal.equal);
        _closedFarmSet := TrieSet.delete<Principal>(_closedFarmSet, msg.caller, Principal.hash(msg.caller), Principal.equal);

        if (status == #NOT_STARTED) {
            _notStartedFarmSet := TrieSet.put<Principal>(_notStartedFarmSet, msg.caller, Principal.hash(msg.caller), Principal.equal);
        } else if (status == #LIVE) {
            _liveFarmSet := TrieSet.put<Principal>(_liveFarmSet, msg.caller, Principal.hash(msg.caller), Principal.equal);
        } else if (status == #FINISHED) {
            _finishedFarmSet := TrieSet.put<Principal>(_finishedFarmSet, msg.caller, Principal.hash(msg.caller), Principal.equal);
        } else if (status == #CLOSED) {
            _closedFarmSet := TrieSet.put<Principal>(_closedFarmSet, msg.caller, Principal.hash(msg.caller), Principal.equal);
        };
    };

    public shared (msg) func updateFarmTVL(tvl : Types.TVL) : async () {
        if (not CollectionUtils.arrayContains(_farms, msg.caller, Principal.equal)) {
            return;
        };

        switch (_farmRewardInfos.get(msg.caller)) {
            case (?info) {
                _farmRewardInfos.put(
                    msg.caller,
                    {
                        initTime = info.initTime;
                        poolToken0TVL = {
                            address = Principal.fromText(tvl.poolToken0.address);
                            standard = tvl.poolToken0.standard;
                            amount = tvl.poolToken0.amount;
                        };
                        poolToken1TVL = {
                            address = Principal.fromText(tvl.poolToken1.address);
                            standard = tvl.poolToken1.standard;
                            amount = tvl.poolToken1.amount;
                        };
                        totalReward = info.totalReward;
                    },
                );
            };
            case (_) {};
        };
    };

    public shared (msg) func addFarmIndex(input : Types.AddFarmIndexArgs) : async () {
        assert (Principal.equal(msg.caller, factoryCid));

        var tempFarmIds = Buffer.Buffer<Principal>(0);
        for (z in _farms.vals()) { tempFarmIds.add(z) };
        tempFarmIds.add(input.farmId);
        _farms := Buffer.toArray(tempFarmIds);

        tempFarmIds := Buffer.Buffer<Principal>(0);
        var poolKeyFarmIds = switch (_poolKeyFarms.get(input.poolKey)) { case (?list) { list }; case (_) { [] }; };
        for (z in poolKeyFarmIds.vals()) { tempFarmIds.add(z) };
        tempFarmIds.add(input.farmId);
        _poolKeyFarms.put(input.poolKey, Buffer.toArray(tempFarmIds));

        tempFarmIds := Buffer.Buffer<Principal>(0);
        var rewardTokenFarmIds = switch (_rewardTokenFarms.get(Principal.fromText(input.rewardToken.address))) {
            case (?list) { list }; case (_) { [] };
        };
        for (z in rewardTokenFarmIds.vals()) { tempFarmIds.add(z) };
        tempFarmIds.add(input.farmId);
        _rewardTokenFarms.put(Principal.fromText(input.rewardToken.address), Buffer.toArray(tempFarmIds));

        _farmRewardInfos.put(
            input.farmId,
            {
                initTime = _getTime();
                poolToken0TVL = {
                    address = Principal.fromText(input.poolToken0.address);
                    standard = input.poolToken0.standard;
                    amount = 0;
                };
                poolToken1TVL = {
                    address = Principal.fromText(input.poolToken1.address);
                    standard = input.poolToken1.standard;
                    amount = 0;
                };
                totalReward = {
                    address = Principal.fromText(input.rewardToken.address);
                    standard = input.rewardToken.standard;
                    amount = input.totalReward;
                };
            },
        );
    };

    public query func getFarms(status : ?Types.FarmStatus) : async Result.Result<[Principal], Text> {
        switch (status) {
            case (? #NOT_STARTED) { return #ok(TrieSet.toArray(_notStartedFarmSet)); };
            case (? #LIVE) { return #ok(TrieSet.toArray(_liveFarmSet)) };
            case (? #FINISHED) { return #ok(TrieSet.toArray(_finishedFarmSet)) };
            case (? #CLOSED) { return #ok(TrieSet.toArray(_closedFarmSet)) };
            case (null) { return #ok(_farms) };
        };
    };

    public query func getAllFarms() : async Result.Result<{ NOT_STARTED : [Principal]; LIVE : [Principal]; FINISHED : [Principal]; CLOSED : [Principal] }, Text> {
        return #ok({
            NOT_STARTED = TrieSet.toArray(_notStartedFarmSet);
            LIVE = TrieSet.toArray(_liveFarmSet);
            FINISHED = TrieSet.toArray(_finishedFarmSet);
            CLOSED = TrieSet.toArray(_closedFarmSet);
        });
    };

    public query func getUserFarms(user : Principal) : async Result.Result<[Principal], Types.Error> {
        switch (_userFarms.get(user)) {
            case (?farmArray) { return #ok(farmArray) };
            case (_) { return #ok([]) };
        };
    };

    public query func getAllUserFarms() : async Result.Result<[(Principal, [Principal])], Types.Error> {
        return #ok(Iter.toArray(_userFarms.entries()));
    };

    public query func getFarmUsers(farm : Principal) : async Result.Result<[Principal], Types.Error> {
        switch (_farmUsers.get(farm)) {
            case (?userArray) { return #ok(userArray) };
            case (_) { return #ok([]) };
        };
    };

    public query func getAllFarmUsers() : async Result.Result<[(Principal, [Principal])], Types.Error> {
        return #ok(Iter.toArray(_farmUsers.entries()));
    };

    public query func getFarmsByPoolKey(poolKey : Text) : async Result.Result<[Principal], Types.Error> {
        switch (_poolKeyFarms.get(poolKey)) {
            case (?farmArray) { return #ok(farmArray) };
            case (_) { return #ok([]) };
        };
    };

    public query func getAllPoolKeyFarms() : async Result.Result<[(Text, [Principal])], Types.Error> {
        return #ok(Iter.toArray(_poolKeyFarms.entries()));
    };

    public query func getFarmsByRewardToken(rewardToken : Principal) : async Result.Result<[Principal], Types.Error> {
        switch (_rewardTokenFarms.get(rewardToken)) {
            case (?farmArray) { return #ok(farmArray) };
            case (_) { return #ok([]) };
        };
    };

    public query func getFarmsByConditions(condition : Types.SearchCondition) : async Result.Result<[Principal], Types.Error> {
        var rewardTokenFarms = switch (condition.rewardToken) {
            case (?_key) { switch (_rewardTokenFarms.get(_key)) { case (?arr) { ?arr }; case (_) { ?[] }; }; }; 
            case (_) { null };
        };
        var poolKeyFarms = switch (condition.poolKey) {
            case (?_key) { switch (_poolKeyFarms.get(_key)) { case (?arr) { ?arr }; case (_) { ?[] }; }; }; case (_) { null };
        };
        var userFarms = switch (condition.user) {
            case (?_key) { switch (_userFarms.get(_key)) { case (?arr) { ?arr }; case (_) { ?[] }; }; }; case (_) { null };
        };
        if (Option.isNull(rewardTokenFarms) and Option.isNull(poolKeyFarms) and Option.isNull(userFarms)) {
            return #ok(_farms);
        };

        var result = _intersectArrays(rewardTokenFarms, poolKeyFarms);
        result := _intersectArrays(?result, userFarms);

        return #ok(result);

    };

    public query func getAllRewardTokenFarms() : async Result.Result<[(Principal, [Principal])], Types.Error> {
        return #ok(Iter.toArray(_rewardTokenFarms.entries()));
    };

    public query func getPrincipalRecord() : async Result.Result<[Principal], Types.Error> {
        return #ok(TrieSet.toArray(_principalRecordSet));
    };

    public query func getTotalAmount() : async Result.Result<{ farmAmount : Nat; principalAmount : Nat }, Types.Error> {
        return #ok({
            farmAmount = _farms.size();
            principalAmount = TrieSet.size(_principalRecordSet);
        });
    };

    public query func getFarmRewardTokenInfo(farm : Principal) : async Result.Result<Types.FarmRewardInfo, Types.Error> {
        switch (_farmRewardInfos.get(farm)) {
            case (?info) { #ok(info) };
            case (_) { return #err(#InternalError("No such Farm.")) };
        };
    };

    public query func getFarmRewardTokenInfos(status : ?Types.FarmStatus) : async Result.Result<[(Principal, Types.FarmRewardInfo)], Types.Error> {
        switch (status) {
            case (? #NOT_STARTED) { return #ok(_getFarmRewardTokenInfos(#NOT_STARTED)); };
            case (? #LIVE) { return #ok(_getFarmRewardTokenInfos(#LIVE)) };
            case (? #FINISHED) { return #ok(_getFarmRewardTokenInfos(#FINISHED)); };
            case (? #CLOSED) { return #ok(_getFarmRewardTokenInfos(#CLOSED)) };
            case (null) {
                var farmRewardInfos = Buffer.Buffer<(Principal, Types.FarmRewardInfo)>(0);
                for (info in _getFarmRewardTokenInfos(#NOT_STARTED).vals()) { farmRewardInfos.add(info); };
                for (info in _getFarmRewardTokenInfos(#LIVE).vals()) { farmRewardInfos.add(info); };
                for (info in _getFarmRewardTokenInfos(#FINISHED).vals()) { farmRewardInfos.add(info); };
                for (info in _getFarmRewardTokenInfos(#CLOSED).vals()) { farmRewardInfos.add(info); };
                return #ok(Buffer.toArray(farmRewardInfos));
            };
        };
    };

    public shared func getCycleInfo() : async Result.Result<Types.CycleInfo, Types.Error> {
        return #ok({
            balance = Cycles.balance();
            available = Cycles.available();
        });
    };

    private func _getFarmRewardTokenInfos(status : Types.FarmStatus) : [(Principal, Types.FarmRewardInfo)] {
        var farmRewardInfos = Buffer.Buffer<(Principal, Types.FarmRewardInfo)>(0);
        if (status == #NOT_STARTED) {
            for (farm in TrieSet.toArray(_notStartedFarmSet).vals()) {
                switch (_farmRewardInfos.get(farm)) {
                    case (?info) { farmRewardInfos.add(farm, info) }; case (_) {};
                };
            };
        } else if (status == #LIVE) {
            for (farm in TrieSet.toArray(_liveFarmSet).vals()) {
                switch (_farmRewardInfos.get(farm)) {
                    case (?info) { farmRewardInfos.add(farm, info) }; case (_) {};
                };
            };
        } else if (status == #FINISHED) {
            for (farm in TrieSet.toArray(_finishedFarmSet).vals()) {
                switch (_farmRewardInfos.get(farm)) {
                    case (?info) { farmRewardInfos.add(farm, info) }; case (_) {};
                };
            };
        } else if (status == #CLOSED) {
            for (farm in TrieSet.toArray(_closedFarmSet).vals()) {
                switch (_farmRewardInfos.get(farm)) {
                    case (?info) { farmRewardInfos.add(farm, info) }; case (_) {};
                };
            };
        };
        return Buffer.toArray(farmRewardInfos);
    };

    private func _intersectArrays(arr1 : ?[Principal], arr2 : ?[Principal]) : [Principal] {
        switch (arr1, arr2) {
            case (null, null) { return []; };
            case (null, ?arr) { return arr; };
            case (?arr, null) { return arr; };
            case (?arr1, ?arr2) {
                var intersection = TrieSet.empty<Principal>();
                for (f1 in arr1.vals()) {
                    label l for (f2 in arr2.vals()) {
                        if (Principal.equal(f1, f2)) {
                            intersection := TrieSet.put<Principal>(intersection, f1, Principal.hash(f1), Principal.equal);
                            break l;
                        };
                    };
                };
                return TrieSet.toArray<Principal>(intersection);
            };
        };
    };

    private func _checkPermission(caller : Principal) {
        assert (Prim.isController(caller));
    };

    private func _getTime() : Nat {
        return Nat64.toNat(Int64.toNat64(Int64.fromInt(Time.now() / 1000000000)));
    };

    // --------------------------- Version Control ------------------------------------
    private var _version : Text = "3.2.0";
    public query func getVersion() : async Text { _version };

    system func preupgrade() {
        _farmRewardInfoEntries := Iter.toArray(_farmRewardInfos.entries());
        _userFarmEntries := Iter.toArray(_userFarms.entries());
        _farmUserEntries := Iter.toArray(_farmUsers.entries());
        _poolKeyFarmEntries := Iter.toArray(_poolKeyFarms.entries());
        _rewardTokenFarmEntries := Iter.toArray(_rewardTokenFarms.entries());
    };

    system func postupgrade() {
        _farmRewardInfoEntries := [];
        _userFarmEntries := [];
        _farmUserEntries := [];
        _poolKeyFarmEntries := [];
        _rewardTokenFarmEntries := [];
    };

    // system func inspect({
    //     arg : Blob;
    //     caller : Principal;
    //     msg : Types.FarmInfo;
    // }) : Bool {
    //     return switch (msg) { };
    // };

    // Sync old farm tvl and reward info, remove after initialization of the data
    public shared (msg) func syncHisData(farmCid : Principal, initTime : Nat) : async Text {
        assert (Prim.isController(msg.caller));

        let farmAct = actor (Principal.toText(farmCid)) : actor {
            // reward token info and reward token amount 
            getFarmInfo : query (user : Text) -> async Result.Result<{
                rewardToken : Types.Token;
                pool : Principal;
                poolToken0 : Types.Token;
                poolToken1 : Types.Token;
                poolFee : Nat;
                startTime : Nat;
                endTime : Nat;
                refunder : Principal;
                totalReward : Nat;
                totalRewardBalance : Nat;
                totalRewardHarvested : Nat;
                totalRewardUnharvested : Nat;
                numberOfStakes : Nat;
                userNumberOfStakes : Nat;
                status : Types.FarmStatus;
                creator : Principal;
                positionIds : [Nat];
            }, Types.Error>;
            // farm principal record
            getStakeRecord : query (offset : Nat, limit : Nat, from : Text) -> async Result.Result<Types.Page<Types.StakeRecord>, Text>;
        };
        var principalSet = TrieSet.empty<Principal>();
        switch (await farmAct.getStakeRecord(0, 100000, "")) {
            case (#ok(stakeRecord)) {
                for (r in stakeRecord.content.vals()) {
                    if (r.transType == #stake) {
                        principalSet := TrieSet.put<Principal>(principalSet, r.from, Principal.hash(r.from), Principal.equal);
                    };
                };
            };
            case (#err(msg)) { };
        };

        switch (await farmAct.getFarmInfo("")) {
            case (#ok(info)) {
                var tempFarmIds = Buffer.Buffer<Principal>(0);
                for (z in _farms.vals()) { tempFarmIds.add(z) };
                tempFarmIds.add(farmCid);
                _farms := Buffer.toArray(tempFarmIds);

                let poolKey = info.poolToken0.address # "_" # info.poolToken1.address # "_" # Nat.toText(info.poolFee);
                tempFarmIds := Buffer.Buffer<Principal>(0);
                var poolKeyFarmIds = switch (_poolKeyFarms.get(poolKey)) { case (?list) { list }; case (_) { [] }; };
                for (z in poolKeyFarmIds.vals()) { tempFarmIds.add(z) };
                tempFarmIds.add(farmCid);
                _poolKeyFarms.put(poolKey, Buffer.toArray(tempFarmIds));

                tempFarmIds := Buffer.Buffer<Principal>(0);
                var rewardTokenFarmIds = switch (_rewardTokenFarms.get(Principal.fromText(info.rewardToken.address))) {
                    case (?list) { list }; case (_) { [] };
                };
                for (z in rewardTokenFarmIds.vals()) { tempFarmIds.add(z) };
                tempFarmIds.add(farmCid);
                _rewardTokenFarms.put(Principal.fromText(info.rewardToken.address), Buffer.toArray(tempFarmIds));

                _farmRewardInfos.put(
                    farmCid,
                    {
                        initTime = initTime;
                        poolToken0TVL = {
                            address = Principal.fromText(info.poolToken0.address);
                            standard = info.poolToken0.standard;
                            amount = 0;
                        };
                        poolToken1TVL = {
                            address = Principal.fromText(info.poolToken1.address);
                            standard = info.poolToken1.standard;
                            amount = 0;
                        };
                        totalReward = {
                            address = Principal.fromText(info.rewardToken.address);
                            standard = info.rewardToken.standard;
                            amount = info.totalReward;
                        };
                    },
                );

                _closedFarmSet := TrieSet.put<Principal>(_closedFarmSet, farmCid, Principal.hash(farmCid), Principal.equal);
                _principalRecordSet := TrieSet.union<Principal>(_principalRecordSet, principalSet, Principal.equal);

                return "ok";
            };
            case (#err(msg)) {
                return debug_show(msg);
            };
        };
    };

};
