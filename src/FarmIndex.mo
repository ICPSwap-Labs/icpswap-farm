import Buffer "mo:base/Buffer";
import Cycles "mo:base/ExperimentalCycles";
import Time "mo:base/Time";
import Nat "mo:base/Nat";
import Nat64 "mo:base/Nat64";
import TrieSet "mo:base/TrieSet";
import Iter "mo:base/Iter";
import Int64 "mo:base/Int64";
import Principal "mo:base/Principal";
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
            var tempFarmIds : Buffer.Buffer<Principal> = Buffer.Buffer<Principal>(0);
            var currentFarmIdList = switch (_userFarms.get(user)) { case (?list) { list }; case (_) { [] }; };
            for (z in currentFarmIdList.vals()) { tempFarmIds.add(z) };
            tempFarmIds.add(msg.caller);
            _userFarms.put(user, Buffer.toArray(tempFarmIds));

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
                _farmRewardInfos.put(msg.caller, {
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
                });
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
        var rewardTokenFarmIds = switch (_rewardTokenFarms.get(Principal.fromText(input.rewardToken.address))) { case (?list) { list }; case (_) { [] }; };
        for (z in rewardTokenFarmIds.vals()) { tempFarmIds.add(z) };
        tempFarmIds.add(input.farmId);
        _rewardTokenFarms.put(Principal.fromText(input.rewardToken.address), Buffer.toArray(tempFarmIds));
        
        _farmRewardInfos.put(input.farmId, {
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
        });
    };

    public query func getFarms(status : ?Types.FarmStatus) : async Result.Result<[Principal], Text> {
        switch (status) {
            case (? #NOT_STARTED) { return #ok(TrieSet.toArray(_notStartedFarmSet)); };
            case (? #LIVE) { return #ok(TrieSet.toArray(_liveFarmSet)); };
            case (? #FINISHED) { return #ok(TrieSet.toArray(_finishedFarmSet)); };
            case (? #CLOSED) { return #ok(TrieSet.toArray(_closedFarmSet)); };
            case (null) { return #ok(_farms) };
        };
    };

    public query func getUserPools(user : Principal) : async Result.Result<[Principal], Types.Error> {
        switch (_userFarms.get(user)) {
            case (?farmArray) { return #ok(farmArray); };
            case (_) { return #ok([]); };
        };
    };

    public query func getPrincipalRecord() : async Result.Result<[Principal], Types.Error> {
        return #ok(TrieSet.toArray(_principalRecordSet));
    };

    public query func getTotalAmount() : async Result.Result<{ farmAmount : Nat; principalAmount : Nat; }, Types.Error> {
        return #ok({
            farmAmount = _farms.size();
            principalAmount = TrieSet.size(_principalRecordSet);
        });
    };

    public query func getFarmRewardTokenInfos(status : ?Types.FarmStatus) : async Result.Result<[(Principal, Types.FarmRewardInfo)], Types.Error> {
        switch (status) {
            case (? #NOT_STARTED) { return #ok(_getFarmRewardTokenInfos(#NOT_STARTED)); };
            case (? #LIVE) { return #ok(_getFarmRewardTokenInfos(#LIVE)); };
            case (? #FINISHED) { return #ok(_getFarmRewardTokenInfos(#FINISHED)); };
            case (? #CLOSED) { return #ok(_getFarmRewardTokenInfos(#CLOSED)); };
            case (null) {
                var farmRewardInfos = Buffer.Buffer<(Principal, Types.FarmRewardInfo)>(0);
                for (info in _getFarmRewardTokenInfos(#NOT_STARTED).vals()) { farmRewardInfos.add(info) };
                for (info in _getFarmRewardTokenInfos(#LIVE).vals()) { farmRewardInfos.add(info) };
                for (info in _getFarmRewardTokenInfos(#FINISHED).vals()) { farmRewardInfos.add(info) };
                for (info in _getFarmRewardTokenInfos(#CLOSED).vals()) { farmRewardInfos.add(info) };
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
                switch (_farmRewardInfos.get(farm)) { case (?info) { farmRewardInfos.add(farm, info); }; case (_) {}; };
            };
        } else if (status == #LIVE) {
            for (farm in TrieSet.toArray(_liveFarmSet).vals()) {
                switch (_farmRewardInfos.get(farm)) { case (?info) { farmRewardInfos.add(farm, info); }; case (_) {}; };
            };
        } else if (status == #FINISHED) {
            for (farm in TrieSet.toArray(_finishedFarmSet).vals()) {
                switch (_farmRewardInfos.get(farm)) { case (?info) { farmRewardInfos.add(farm, info); }; case (_) {}; };
            };
        } else if (status == #CLOSED) {
            for (farm in TrieSet.toArray(_closedFarmSet).vals()) {
                switch (_farmRewardInfos.get(farm)) { case (?info) { farmRewardInfos.add(farm, info); }; case (_) {}; };
            };
        };
        return Buffer.toArray(farmRewardInfos);
    };

    private func _checkPermission(caller : Principal) {
        assert (Prim.isController(caller));
    };

    private func _getTime() : Nat {
        return Nat64.toNat(Int64.toNat64(Int64.fromInt(Time.now() / 1000000000)));
    };

    // --------------------------- Version Control ------------------------------------
    private var _version : Text = "3.1.0";
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
};
