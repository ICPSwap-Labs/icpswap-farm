import Principal "mo:base/Principal";
import Int "mo:base/Int";
import Time "mo:base/Time";
import Buffer "mo:base/Buffer";
import Order "mo:base/Order";
import Debug "mo:base/Debug";
import Error "mo:base/Error";
import Nat "mo:base/Nat";
import Option "mo:base/Option";
import Text "mo:base/Text";
import Iter "mo:base/Iter";
import HashMap "mo:base/HashMap";
import Types "../Types";

module FarmInfoService {

    public type State = {
        notStartedFarmEntries : [(Principal, Types.TVL)];
        liveFarmEntries : [(Principal, Types.TVL)];
        finishedFarmEntries : [(Principal, Types.TVL)];
        closedFarmEntries : [(Principal, Types.TVL)];
    };

    public class Service(initState : State) {
        private var _notStartedFarmMap : HashMap.HashMap<Principal, Types.TVL> = HashMap.fromIter(initState.notStartedFarmEntries.vals(), 10, Principal.equal, Principal.hash);
        private var _liveFarmMap : HashMap.HashMap<Principal, Types.TVL> = HashMap.fromIter(initState.liveFarmEntries.vals(), 10, Principal.equal, Principal.hash);
        private var _finishedFarmMap : HashMap.HashMap<Principal, Types.TVL> = HashMap.fromIter(initState.finishedFarmEntries.vals(), 10, Principal.equal, Principal.hash);
        private var _closedFarmMap : HashMap.HashMap<Principal, Types.TVL> = HashMap.fromIter(initState.closedFarmEntries.vals(), 10, Principal.equal, Principal.hash);

        public func getNotStartedFarms() : HashMap.HashMap<Principal, Types.TVL> {
            return _notStartedFarmMap;
        };
        public func getLiveFarmFarms() : HashMap.HashMap<Principal, Types.TVL> {
            return _liveFarmMap;
        };
        public func getFinishedFarms() : HashMap.HashMap<Principal, Types.TVL> {
            return _finishedFarmMap;
        };
        public func getClosedFarms() : HashMap.HashMap<Principal, Types.TVL> {
            return _closedFarmMap;
        };

        public func putNotStartedFarm(farmCid : Principal, TVL : Types.TVL) : () {
            return _notStartedFarmMap.put(farmCid, TVL);
        };
        public func putLiveFarm(farmCid : Principal, TVL : Types.TVL) : () {
            return _liveFarmMap.put(farmCid, TVL);
        };
        public func putFinishedFarm(farmCid : Principal, TVL : Types.TVL) : () {
            return _finishedFarmMap.put(farmCid, TVL);
        };
        public func putClosedFarm(farmCid : Principal, TVL : Types.TVL) : () {
            return _closedFarmMap.put(farmCid, TVL);
        };

        public func removeNotStartedFarm(farmCid : Principal) : Bool {
            switch (_notStartedFarmMap.remove(farmCid)) {
                case (?tvl) { true };
                case (null) { false };
            };
        };
        public func removeLiveFarm(farmCid : Principal) : Bool {
            switch (_liveFarmMap.remove(farmCid)) {
                case (?tvl) { true };
                case (null) { false };
            };
        };
        public func removeFinishedFarm(farmCid : Principal) : Bool {
            switch (_finishedFarmMap.remove(farmCid)) {
                case (?tvl) { true };
                case (null) { false };
            };
        };
        public func removeClosedFarm(farmCid : Principal) : Bool {
            switch (_closedFarmMap.remove(farmCid)) {
                case (?tvl) { true };
                case (null) { false };
            };
        };

        public func deleteNotStartedFarm(farmCid : Principal) : () {
            _notStartedFarmMap.delete(farmCid);
        };
        public func deleteLiveFarm(farmCid : Principal) : () {
            _liveFarmMap.delete(farmCid);
        };
        public func deleteFinishedFarm(farmCid : Principal) : () {
            _finishedFarmMap.delete(farmCid);
        };
        public func deleteClosedFarm(farmCid : Principal) : () {
            _closedFarmMap.delete(farmCid);
        };

        public func getNotStartedFarmBuffer() : Buffer.Buffer<(Principal, Types.TVL)> {
            var buffer = Buffer.Buffer<(Principal, Types.TVL)>(0);
            for (tvl in Iter.toArray(_notStartedFarmMap.entries()).vals()) {
                buffer.add(tvl);
            };
            return buffer;
        };
        public func getLiveFarmBuffer() : Buffer.Buffer<(Principal, Types.TVL)> {
            var buffer = Buffer.Buffer<(Principal, Types.TVL)>(0);
            for (tvl in Iter.toArray(_liveFarmMap.entries()).vals()) {
                buffer.add(tvl);
            };
            return buffer;
        };
        public func getFinishedFarmBuffer() : Buffer.Buffer<(Principal, Types.TVL)> {
            var buffer = Buffer.Buffer<(Principal, Types.TVL)>(0);
            for (tvl in Iter.toArray(_finishedFarmMap.entries()).vals()) {
                buffer.add(tvl);
            };
            return buffer;
        };
        public func getClosedFarmBuffer() : Buffer.Buffer<(Principal, Types.TVL)> {
            var buffer = Buffer.Buffer<(Principal, Types.TVL)>(0);
            for (tvl in Iter.toArray(_closedFarmMap.entries()).vals()) {
                buffer.add(tvl);
            };
            return buffer;
        };

        public func getTargetArray(status : Types.FarmStatus) : [(Principal, Types.TVL)] {
            if (status == #NOT_STARTED) {
                return Buffer.toArray(getNotStartedFarmBuffer());
            } else if (status == #LIVE) {
                return Buffer.toArray(getLiveFarmBuffer());
            } else if (status == #FINISHED) {
                return Buffer.toArray(getFinishedFarmBuffer());
            } else if (status == #CLOSED) {
                return Buffer.toArray(getClosedFarmBuffer());
            } else {
                return Buffer.toArray(Buffer.Buffer<(Principal, Types.TVL)>(0));
            };
        };

        public func getAllArray() : [(Principal, Types.TVL)] {
            var buffer = Buffer.Buffer<(Principal, Types.TVL)>(0);
            buffer.append(getNotStartedFarmBuffer());
            buffer.append(getLiveFarmBuffer());
            buffer.append(getFinishedFarmBuffer());
            buffer.append(getClosedFarmBuffer());
            return Buffer.toArray(buffer);
        };

        public func getAllFarmId() : [Principal] {
            var buffer = Buffer.Buffer<Principal>(0);
            for ((key, value) in Iter.toArray(_notStartedFarmMap.entries()).vals()) {
                buffer.add(key);
            };
            for ((key, value) in Iter.toArray(_liveFarmMap.entries()).vals()) {
                buffer.add(key);
            };
            for ((key, value) in Iter.toArray(_finishedFarmMap.entries()).vals()) {
                buffer.add(key);
            };
            for ((key, value) in Iter.toArray(_closedFarmMap.entries()).vals()) {
                buffer.add(key);
            };
            return Buffer.toArray(buffer);
        };

        public func getState() : State {
            return {
                notStartedFarmEntries = Iter.toArray(_notStartedFarmMap.entries());
                liveFarmEntries = Iter.toArray(_liveFarmMap.entries());
                finishedFarmEntries = Iter.toArray(_finishedFarmMap.entries());
                closedFarmEntries = Iter.toArray(_closedFarmMap.entries());
            };
        };
    };
};
