import Nat "mo:base/Nat";
import Principal "mo:base/Principal";
import HashMap "mo:base/HashMap";
import Iter "mo:base/Iter";
import Array "mo:base/Array";
import Types "../Types";

module TokenHolder {
    type TokenBalance = Types.TokenBalance;
    type Token = Types.Token;

    public type State = {
        balances : [(Principal, Nat)];
    };

    public class Service(initState : State) {
        private var _balances : HashMap.HashMap<Principal, Nat> = HashMap.fromIter<Principal, Nat>(initState.balances.vals(), 100000, Principal.equal, Principal.hash);

        private func _setBalance(principal : Principal, balance : Nat) {
            if (balance == 0) {
                _balances.delete(principal);
            } else {
                _balances.put(principal, balance);
            };
        };

        public func getAllBalances() : HashMap.HashMap<Principal, Nat> {
            _balances;
        };

        public func getBalance(account : Principal) : Nat {
            return switch (_balances.get(account)) {
                case (?ab) { ab };
                case (_) { 0 };
            };
        };

        public func deposit(principal : Principal, amount : Nat) : Bool {
            switch (_balances.get(principal)) {
                case (?ab) {
                    _setBalance(principal, ab + amount);
                };
                case (_) {
                    _setBalance(principal, amount);
                };
            };
            return true;
        };

        public func withdraw(principal : Principal, amount : Nat) : Bool {
            switch (_balances.get(principal)) {
                case (?ab) {
                    if (ab < amount) {
                        return false;
                    };
                    _setBalance(principal, Nat.sub(ab, amount));
                    return true;
                };
                case (_) { return false };
            };
        };

        public func getState() : State {
            return {
                balances = Iter.toArray(_balances.entries());
            };
        };
    };
};
