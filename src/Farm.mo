import Array "mo:base/Array";
import Buffer "mo:base/Buffer";
import Cycles "mo:base/ExperimentalCycles";
import Error "mo:base/Error";
import Hash "mo:base/Hash";
import Blob "mo:base/Blob";
import Debug "mo:base/Debug";
import Float "mo:base/Float";
import Nat8 "mo:base/Nat8";
import HashMap "mo:base/HashMap";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import Time "mo:base/Time";
import Timer "mo:base/Timer";
import Nat "mo:base/Nat";
import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Text "mo:base/Text";
import Option "mo:base/Option";
import CollectionUtils "mo:commons/utils/CollectionUtils";
import IntUtils "mo:commons/math/SafeInt/IntUtils";
import SafeUint "mo:commons/math/SafeUint";
import SafeInt "mo:commons/math/SafeInt";
import TokenFactory "mo:token-adapter/TokenFactory";
import Types "./Types";
import TokenHolder "./components/TokenHolder";
import Prim "mo:⛔";
import SqrtPriceMath "mo:icpswap-v3-service/libraries/SqrtPriceMath";
import TickMath "mo:icpswap-v3-service/libraries/TickMath";

shared (initMsg) actor class Farm(
  initArgs : Types.InitFarmArgs
) = this {

  private stable var _canisterId : ?Principal = null;

  private stable var _rewardTokenHolderState : TokenHolder.State = { balances = []; };
  private var _rewardTokenHolderService : TokenHolder.Service = TokenHolder.Service(_rewardTokenHolderState);

  // reward meta
  private stable var _status : Types.FarmStatus = #NOT_STARTED;
  private stable var _rewardPerCycle : Nat = 0;
  private stable var _currentCycleCount : Nat = 0;
  private stable var _totalCycleCount : Nat = 0;
  private stable var _totalReward = initArgs.totalReward;
  private stable var _totalRewardBalance = initArgs.totalReward;
  private stable var _totalRewardHarvested = 0;
  private stable var _totalRewardUnharvested = 0;
  private stable var _totalRewardFee = 0;
  private stable var _totalLiquidity = 0;
  private stable var _TVL : Types.TVL = {
    poolToken0 = { address = ""; standard = ""; amount = 0; };
    poolToken1 = { address = ""; standard = ""; amount = 0; };
  };

  // position pool metadata
  private stable var _poolToken0 = { address = ""; standard = "" };
  private stable var _poolToken1 = { address = ""; standard = "" };
  private stable var _poolToken0Symbol = "";
  private stable var _poolToken1Symbol = "";
  private stable var _poolToken0Decimals = 0;
  private stable var _poolToken1Decimals = 0;
  private stable var _poolToken0Amount = 0;
  private stable var _poolToken1Amount = 0;
  private stable var _poolFee : Nat = 0;
  private stable var _poolMetadata = {
    sqrtPriceX96 : Nat = 0;
    tick : Int = 0;
  };

  // reward token metadata
  private stable var _rewardTokenFee = 0;
  private stable var _rewardTokenDecimals = 0;

  // limit params
  private stable var _positionNumLimit : Nat = 500;
  private stable var _token0AmountLimit : Nat = initArgs.token0AmountLimit;
  private stable var _token1AmountLimit : Nat = initArgs.token1AmountLimit;
  private stable var _priceInsideLimit : Bool = initArgs.priceInsideLimit;

  // stake metadata
  private stable var _positionIds : [Nat] = [];
  private stable var _depositEntries : [(Nat, Types.Deposit)] = [];
  private var _depositMap = HashMap.fromIter<Nat, Types.Deposit>(_depositEntries.vals(), 10, Types.equal, Types.hash);
  private stable var _userPositionEntries : [(Principal, [Nat])] = [];
  private var _userPositionMap = HashMap.fromIter<Principal, [Nat]>(_userPositionEntries.vals(), 10, Principal.equal, Principal.hash);

  // record
  private stable var _stakeRecordList : [Types.StakeRecord] = [];
  private var _stakeRecordBuffer : Buffer.Buffer<Types.StakeRecord> = Buffer.Buffer<Types.StakeRecord>(0);
  private stable var _distributeRecordList : [Types.DistributeRecord] = [];
  private var _distributeRecordBuffer : Buffer.Buffer<Types.DistributeRecord> = Buffer.Buffer<Types.DistributeRecord>(0);

  // APR
  private stable var _timeConst : Float = 360 * 24 * 3600;
  private stable var _rewardTokenDecimalsConst : Float = 0;
  private stable var _token0DecimalsConst : Float = 0;
  private stable var _token1DecimalsConst : Float = 0;
  private stable var _avgAPR : Float = 0;
  private stable var _APRRecordList : [(Nat, Float)] = [];
  private var _APRRecordBuffer : Buffer.Buffer<(Nat, Float)> = Buffer.Buffer<(Nat, Float)>(0);
  private stable var _nodeIndexAct = actor (Principal.toText(initArgs.nodeIndexCid)) : actor {
    tokenStorage : query (tokenId : Text) -> async ?Text;
  };

  let _rewardTokenAdapter = TokenFactory.getAdapter(initArgs.rewardToken.address, initArgs.rewardToken.standard);
  private stable var _swapPoolAct = actor (Principal.toText(initArgs.pool)) : actor {
    metadata : query () -> async Result.Result<Types.PoolMetadata, Types.Error>;
    getUserPosition : query (positionId : Nat) -> async Result.Result<Types.UserPositionInfo, Types.Error>;
    transferPosition : shared (from : Principal, to : Principal, positionId : Nat) -> async Result.Result<Bool, Types.Error>;
  };
  private stable var _farmIndexAct = actor (Principal.toText(initArgs.farmIndexCid)) : actor {
    updateUserInfo : shared (users : [Principal]) -> async ();
    updateFarmStatus : shared (status : Types.FarmStatus) -> async ();
    updateFarmTVL : shared (tvl : Types.TVL) -> async ();
  };

  private stable var _inited : Bool = false;
  public shared (msg) func init() : async () {
    _checkPermission(msg.caller);

    assert (not _inited);

    _canisterId := ?Principal.fromActor(this);
    var tempRewardTotalCount = SafeUint.Uint512(initArgs.endTime).sub(SafeUint.Uint512(initArgs.startTime)).div(SafeUint.Uint512(initArgs.secondPerCycle));
    _totalCycleCount := tempRewardTotalCount.val();
    _rewardPerCycle := SafeUint.Uint512(_totalReward).div(tempRewardTotalCount).val();

    let poolMetadata = switch (await _swapPoolAct.metadata()) {
      case (#ok(poolMetadata)) { poolMetadata };
      case (#err(_)) {
        {
          key = "";
          token0 = { address = ""; standard = "" };
          token1 = { address = ""; standard = "" };
          fee = 0;
          tick = 0;
          liquidity = 0;
          sqrtPriceX96 = 0;
          maxLiquidityPerTick = 0;
        };
      };
    };
    _poolFee := poolMetadata.fee;
    _poolToken0 := poolMetadata.token0;
    _poolToken1 := poolMetadata.token1;

    let _poolToken0Adapter = TokenFactory.getAdapter(poolMetadata.token0.address, poolMetadata.token0.standard);
    let _poolToken1Adapter = TokenFactory.getAdapter(poolMetadata.token1.address, poolMetadata.token1.standard);

    _poolToken0Symbol := await _poolToken0Adapter.symbol();
    _poolToken1Symbol := await _poolToken1Adapter.symbol();
    _poolToken0Decimals := Nat8.toNat(await _poolToken0Adapter.decimals());
    _poolToken1Decimals := Nat8.toNat(await _poolToken1Adapter.decimals());

    _rewardTokenFee := await _rewardTokenAdapter.fee();
    _rewardTokenDecimals := Nat8.toNat(await _rewardTokenAdapter.decimals());

    _rewardTokenDecimalsConst := Float.pow(10, Float.fromInt(IntUtils.toInt(_rewardTokenDecimals, 512)));
    _token0DecimalsConst := Float.pow(10, Float.fromInt(IntUtils.toInt(_poolToken0Decimals, 512)));
    _token1DecimalsConst := Float.pow(10, Float.fromInt(IntUtils.toInt(_poolToken1Decimals, 512)));

    _poolMetadata := {
      sqrtPriceX96 = poolMetadata.sqrtPriceX96;
      tick = poolMetadata.tick;
    };
    _TVL := {
      poolToken0 = { address = _poolToken0.address; standard = _poolToken0.standard; amount = 0; };
      poolToken1 = { address = _poolToken1.address; standard = _poolToken1.standard; amount = 0; };
    };

    _inited := true;
  };

  public shared (msg) func stake(positionId : Nat) : async Result.Result<Text, Types.Error> {
    var nowTime = _getTime();
    switch (_status) {
      case (#LIVE) {};
      case (_) { return #err(#InternalError("Farm is not available for now")) };
    };

    // ----- legality check start -----
    switch (_depositMap.get(positionId)) {
      case (?deposit) {
        return #err(#InternalError("Position has already been staked"));
      };
      case (_) {};
    };
    var positionInfo = switch (await _swapPoolAct.getUserPosition(positionId)) {
      case (#ok(result)) { result };
      case (#err(code)) {
        return #err(#InternalError("Get user position " # debug_show (positionId) # " failed: " # debug_show (code)));
      };
    };
    if (_positionIds.size() >= _positionNumLimit) {
      return #err(#InternalError("The number of staked positions reaches the upper limit"));
    };
    if (_priceInsideLimit and (_poolMetadata.tick > positionInfo.tickUpper or _poolMetadata.tick < positionInfo.tickLower)) {
      return #err(#InternalError("Current price in pool is not in the price range of the position"));
    };
    let positionTokenAmounts = switch (_getTokenAmountByLiquidity(positionInfo.tickLower, positionInfo.tickUpper, positionInfo.liquidity)) {
      case (#ok(result)) { result };
      case (#err(_)) { { amount0 = 0; amount1 = 0 } };
    };
    if (_token0AmountLimit != 0 and positionTokenAmounts.amount0 < _token0AmountLimit) {
      return #err(#InternalError(
        "The quantity of " # _poolToken0Symbol # " does not reach the low limit: " 
        # debug_show(Float.div(Float.fromInt(SafeInt.Int256(_token0AmountLimit).val()), Float.fromInt(SafeInt.Int256(10 ** _poolToken0Decimals).val())))
      ));
    };
    if (_token1AmountLimit != 0 and positionTokenAmounts.amount1 < _token1AmountLimit) {
      return #err(#InternalError(
        "The quantity of " # _poolToken1Symbol # " does not reach the low limit: "
        # debug_show(Float.div(Float.fromInt(SafeInt.Int256(_token1AmountLimit).val()), Float.fromInt(SafeInt.Int256(10 ** _poolToken1Decimals).val())))
      ));
    };
    if (positionInfo.liquidity <= 0) {
      return #err(#InternalError("Can not stake a position with no liquidity"));
    };
    // ----- legality check end -----

    switch (await _swapPoolAct.transferPosition(msg.caller, Principal.fromActor(this), positionId)) {
      case (#ok(status)) {
        var tempPositionIds : Buffer.Buffer<Nat> = Buffer.Buffer<Nat>(0);
        var currentPositionIdList = switch (_userPositionMap.get(msg.caller)) {
          case (?list) { list };
          case (_) { [] };
        };
        for (z in currentPositionIdList.vals()) { tempPositionIds.add(z) };
        tempPositionIds.add(positionId);
        _userPositionMap.put(msg.caller, Buffer.toArray(tempPositionIds));

        _depositMap.put(
          positionId,
          {
            owner = msg.caller;
            holder = Principal.fromActor(this);
            positionId = positionId;
            tickLower = positionInfo.tickLower;
            tickUpper = positionInfo.tickUpper;
            liquidity = positionInfo.liquidity;
            rewardAmount = 0;
            initTime = nowTime;
            lastDistributeTime = 0;
            token0Amount = positionTokenAmounts.amount0;
            token1Amount = positionTokenAmounts.amount1;
          },
        );
        // update TVL
        _TVL := {
          poolToken0 = { address = _TVL.poolToken0.address; standard = _TVL.poolToken0.standard; amount = _TVL.poolToken0.amount + IntUtils.toNat(positionTokenAmounts.amount0, 512); };
          poolToken1 = { address = _TVL.poolToken1.address; standard = _TVL.poolToken1.standard; amount = _TVL.poolToken1.amount + IntUtils.toNat(positionTokenAmounts.amount1, 512); };
        };

        // update position id
        var tempGlobalPositionIds = Buffer.Buffer<Nat>(0);
        for (z in _positionIds.vals()) { tempGlobalPositionIds.add(z) };
        tempGlobalPositionIds.add(positionId);
        _positionIds := Buffer.toArray(tempGlobalPositionIds);

        _totalLiquidity := _totalLiquidity + positionInfo.liquidity;

        // stake record
        _stakeRecordBuffer.add({
          timestamp = nowTime;
          transType = #stake;
          positionId = positionId;
          from = msg.caller;
          to = Principal.fromActor(this);
          amount = 0;
          liquidity = positionInfo.liquidity;
        });

        ignore Timer.setTimer<system>(#seconds (5), _updateUserInfo);

        return #ok("Staked successfully");
      };
      case (#err(msg)) {
        return #err(#InternalError("Transfer position failed: " # debug_show (msg)));
      };
    };
  };

  public shared (msg) func unstake(positionId : Nat) : async Result.Result<Text, Types.Error> {
    var nowTime = _getTime();
    var deposit : Types.Deposit = switch (_depositMap.get(positionId)) {
      case (?d) { d };
      case (_) { return #err(#InternalError("No such position")) };
    };

    switch (_status) {
      case (#LIVE) {
        if (Principal.notEqual(deposit.owner, msg.caller)) {
          return #err(#InternalError("You are not the owner of the position"));
        };
      };
      case (_) {
        if (Principal.notEqual(deposit.owner, msg.caller) and (not _hasAdminPermission(msg.caller))) {
          return #err(#InternalError("Only the owner/admin can unstake the other's position after the incentive end"));
        };
      };
    };

    switch (await _swapPoolAct.transferPosition(Principal.fromActor(this), deposit.owner, positionId)) {
      case (#ok(status)) {
        let distributedFeeResult = _distributeFee(deposit.rewardAmount);
        ignore _rewardTokenHolderService.deposit(deposit.owner, distributedFeeResult.rewardRedistribution);
        _totalRewardUnharvested := _totalRewardUnharvested - deposit.rewardAmount;
        _totalRewardHarvested := _totalRewardHarvested + distributedFeeResult.rewardRedistribution;
        _totalRewardFee := _totalRewardFee + distributedFeeResult.rewardFee;
        _totalLiquidity := _totalLiquidity - deposit.liquidity;
        // unstake reward record
        _stakeRecordBuffer.add({
          timestamp = nowTime;
          transType = #unstake;
          positionId = positionId;
          from = Principal.fromActor(this);
          to = deposit.owner;
          amount = distributedFeeResult.rewardRedistribution;
          liquidity = deposit.liquidity;
        });

        switch (_userPositionMap.get(deposit.owner)) {
          case (?list) {
            var currentPositionIdList = CollectionUtils.arrayRemove<Nat>(list, positionId, Types.equal);
            if (0 == currentPositionIdList.size()) {
              _userPositionMap.delete(deposit.owner);
            } else {
              _userPositionMap.put(deposit.owner, currentPositionIdList);
            };
          };
          case (_) {};
        };
        _positionIds := CollectionUtils.arrayRemove<Nat>(_positionIds, positionId, Types.equal);

        _depositMap.delete(positionId);

        /**
          This involves uncertain changes in the amount of tokens due to pool price changes, 
          so if it is determined that something will go wrong with subtraction, 
          drop this part of the TVL update and wait for a uniform update at distribution.
        */
        // update TVL
        let token0Amount = IntUtils.toNat(deposit.token0Amount, 512);
        let token1Amount = IntUtils.toNat(deposit.token1Amount, 512);
        if (_TVL.poolToken0.amount >= token0Amount and _TVL.poolToken1.amount >= token1Amount) {
          _TVL := {
            poolToken0 = { address = _TVL.poolToken0.address; standard = _TVL.poolToken0.standard; amount = _TVL.poolToken0.amount - token0Amount; };
            poolToken1 = { address = _TVL.poolToken1.address; standard = _TVL.poolToken1.standard; amount = _TVL.poolToken1.amount - token1Amount; };
          };
        };

        ignore Timer.setTimer<system>(#seconds (5), _updateUserInfo);

        return #ok("Unstaked successfully");
      };
      case (msg) {
        return #err(#InternalError("Transfer position failed: " # debug_show (msg)));
      };
    };
  };

  public shared ({ caller }) func withdraw() : async Result.Result<Nat, Types.Error> {
    if (Principal.isAnonymous(caller)) return #err(#InternalError("Illegal anonymous call"));
    var canisterId = Principal.fromActor(this);
    var balance : Nat = _rewardTokenHolderService.getBalance(caller);
    if (balance <= _rewardTokenFee) { return #ok(0) };
    // if (balance <= _rewardTokenFee) { return #err(#InsufficientFunds) };
    if (_rewardTokenHolderService.withdraw(caller, balance)) {
      var amount : Nat = Nat.sub(balance, _rewardTokenFee);
      var preTransIndex = _preTransfer(caller, canisterId, null, caller, "withdraw", initArgs.rewardToken, amount, _rewardTokenFee);
      try {
        switch (await _rewardTokenAdapter.transfer({ 
          from = { owner = canisterId; subaccount = null }; from_subaccount = null; 
          to = { owner = caller; subaccount = null }; 
          amount = amount; 
          fee = ?_rewardTokenFee; 
          memo = Option.make(_natToBlob(preTransIndex));  
          created_at_time = null 
        })) {
          case (#Ok(index)) {
            _postTransferComplete(preTransIndex);
            return #ok(amount);
          };
          case (#Err(msg)) {
            _postTransferError(preTransIndex, debug_show(msg));
            return #err(#InternalError(debug_show (msg)));
          };
        };
      } catch (e) {
        let msg: Text = debug_show (Error.message(e));
        _postTransferError(preTransIndex, msg);
        return #err(#InternalError(msg));
      };
    } else {
      return #err(#InsufficientFunds);
    };
  };

  public shared (msg) func finishManually() : async Result.Result<Text, Types.Error> {
    _checkAdminPermission(msg.caller);
    _status := #FINISHED;
    await _farmIndexAct.updateFarmStatus(_status);
    return #ok("Finish farm successfully");
  };

  public shared (msg) func restartManually() : async Result.Result<Text, Types.Error> {
    _checkAdminPermission(msg.caller);
    _status := #LIVE;
    await _farmIndexAct.updateFarmStatus(_status);
    return #ok("Restart farm successfully");
  };

  public shared (msg) func sendRewardManually() : async Result.Result<Text, Types.Error> {
    _checkAdminPermission(msg.caller);
    switch (_status) {
      case (#NOT_STARTED) {
        return #err(#InternalError("Can not send reward manually before finishing."));
      };
      case (#LIVE) {
        return #err(#InternalError("Can not send reward manually before finishing."));
      };
      case (_) {
        if (_positionIds.size() > 0) {
          return #err(#InternalError("Please unstake all positions first."));
        };
        var canisterId = Principal.fromActor(this);
        var preTransIndexBalanceList : Buffer.Buffer<(Principal, (Nat, Nat))> = Buffer.Buffer<(Principal, (Nat, Nat))>(0);
        var insufficientFundList : Buffer.Buffer<(Principal, Nat)> = Buffer.Buffer<(Principal, Nat)>(0);
        for ((principal, balance) in _rewardTokenHolderService.getAllBalances().entries()) {
          if (balance > _rewardTokenFee) {
            var amount = balance - _rewardTokenFee;
            var preTransIndex = _preTransfer(principal, canisterId, null, principal, "withdraw", initArgs.rewardToken, amount, _rewardTokenFee);
            preTransIndexBalanceList.add((principal, (preTransIndex, balance)));
          } else {
            insufficientFundList.add(principal, balance);
          };
        };
        for ((principal, balance) in insufficientFundList.vals()) {
          ignore _rewardTokenHolderService.withdraw(principal, balance);
        };
        var passedIndexList : Buffer.Buffer<Nat> = Buffer.Buffer<Nat>(0);
        var failedIndexList : Buffer.Buffer<(Nat, Text)> = Buffer.Buffer<(Nat, Text)>(0);
        for ((principal, (preTransIndex, balance)) in preTransIndexBalanceList.vals()) {
          try {
            switch (await _rewardTokenAdapter.transfer({
              from = { owner = canisterId; subaccount = null }; from_subaccount = null; 
              to = { owner = principal; subaccount = null }; 
              amount = balance - _rewardTokenFee;
              fee = ?_rewardTokenFee; 
              memo = Option.make(_natToBlob(preTransIndex));  
              created_at_time = null 
            })) {
              case (#Ok(index)) {
                passedIndexList.add(preTransIndex);
              };
              case (#Err(msg)) {
                failedIndexList.add((preTransIndex, debug_show (msg)));
              };
            };
          } catch (e) {
            failedIndexList.add((preTransIndex, debug_show (Error.message(e))));
          };
        };
        for ((principal, (preTransIndex, balance)) in preTransIndexBalanceList.vals()) {
          ignore _rewardTokenHolderService.withdraw(principal, balance);
        };
        for (preTransIndex in passedIndexList.vals()) {
          _postTransferComplete(preTransIndex);
        };
        for ((preTransIndex, msg) in failedIndexList.vals()) {
          _postTransferError(preTransIndex, msg);
        };
        return #ok("Send reward successfully");
      };
    };
  };
  
  public shared(msg) func removeErrorTransferLog(index: Nat, rollback: Bool) : async () {
    _checkAdminPermission(msg.caller);
    switch (_transferLog.get(index)) {
      case (?log) {
        _postTransferComplete(index);
        if (rollback ) { 
          if (Text.equal("error", log.result) or (Text.equal(log.result, "processing") and ((Nat.sub(Int.abs(Time.now()), log.timestamp) / NANOSECONDS_PER_SECOND) > SECOND_PER_DAY))) {
            ignore _rewardTokenHolderService.deposit(log.owner, log.amount);
          } else {
            Prim.trap("rollback error: Error status or insufficient time interval");
          };
        };
      };
      case (_) {};
    };
  };

  public shared (msg) func withdrawRewardFee() : async Result.Result<Text, Types.Error> {
    assert (Principal.equal(msg.caller, initArgs.feeReceiverCid));

    var nowTime = _getTime();
    if (_totalRewardFee > _rewardTokenFee) {
      let totalRewardFee = _totalRewardFee;
      var amount = _totalRewardFee - _rewardTokenFee;
      try {
        switch (await _rewardTokenAdapter.transfer({ from = { owner = Principal.fromActor(this); subaccount = null }; from_subaccount = null; to = { owner = initArgs.feeReceiverCid; subaccount = null }; amount = amount; fee = ?_rewardTokenFee; memo = null; created_at_time = null })) {
          case (#Ok(index)) {
            _stakeRecordBuffer.add({
              timestamp = nowTime;
              transType = #withdraw;
              positionId = 0;
              from = Principal.fromActor(this);
              to = initArgs.feeReceiverCid;
              amount = totalRewardFee;
              liquidity = 0;
            });
            _totalRewardFee := 0;
            return #ok("Withdraw reward fee successfully");
          };
          case (#Err(code)) {
            _errorLogBuffer.add("Withdraw reward fee failed at " # debug_show (nowTime) # " . code: " # debug_show (code) # ".");
            return #err(#InternalError("Withdraw reward fee failed at " # debug_show (nowTime) # " . code: " # debug_show (code) # "."));
          };
        };
      } catch (e) {
        _errorLogBuffer.add("Withdraw reward fee failed at " # debug_show (nowTime) # " . Msg: " # debug_show (Error.message(e)) # ".");
        return #err(#InternalError("Withdraw reward fee failed at " # debug_show (nowTime) # " . Msg: " # debug_show (Error.message(e)) # "."));
      };
    } else {
      _totalRewardFee := 0;
      return #err(#InternalError("Withdraw reward fee failed: InsufficientFunds."));
    };
  };

  public shared (msg) func close() : async Result.Result<Text, Types.Error> {
    _checkAdminPermission(msg.caller);
    if (_positionIds.size() > 0) {
      return #err(#InternalError("Please unstake all positions first."));
    };
    if (_totalRewardFee > 0) {
      return #err(#InternalError("Please withdraw reward fee first."));
    };
    if (_rewardTokenHolderService.getAllBalances().size() > 0) {
      return #err(#InternalError("Please send reward back to users first."));
    };

    var nowTime = _getTime();
    var balance = await _rewardTokenAdapter.balanceOf({
      owner = Principal.fromActor(this);
      subaccount = null;
    });

    Timer.cancelTimer(_distributeRewardPerCycle);
    Timer.cancelTimer(_syncPoolMetaPer60s);
    Timer.cancelTimer(_updateStatusPer60s);
    Timer.cancelTimer(_updateTVLPer10m);
    Timer.cancelTimer(_updateRewardTokenFeePer1h);
    Timer.cancelTimer(_updateAPRPer30m);

    if (balance > _rewardTokenFee) {
      var amount = balance - _rewardTokenFee;
      try {
        switch (await _rewardTokenAdapter.transfer({ from = { owner = Principal.fromActor(this); subaccount = null }; from_subaccount = null; to = { owner = initArgs.refunder; subaccount = null }; amount = amount; fee = ?_rewardTokenFee; memo = null; created_at_time = null })) {
          case (#Ok(index)) {
            await _farmIndexAct.updateFarmStatus(#CLOSED);
            await _farmIndexAct.updateFarmTVL({
              poolToken0 = { address = _TVL.poolToken0.address; standard = _TVL.poolToken0.standard; amount = 0; };
              poolToken1 = { address = _TVL.poolToken1.address; standard = _TVL.poolToken1.standard; amount = 0; };
            });
            await _farmIndexAct.updateUserInfo(Iter.toArray(_userPositionMap.keys()));
            _stakeRecordBuffer.add({
              timestamp = nowTime;
              transType = #harvest;
              positionId = 0;
              from = Principal.fromActor(this);
              to = initArgs.refunder;
              amount = balance;
              liquidity = 0;
            });
            _totalRewardBalance := 0;
            _status := #CLOSED;
            _TVL := {
              poolToken0 = { address = _TVL.poolToken0.address; standard = _TVL.poolToken0.standard; amount = 0; };
              poolToken1 = { address = _TVL.poolToken1.address; standard = _TVL.poolToken1.standard; amount = 0; };
            };
            var totalAPR : Float = 0;
            for ((time, apr) in Buffer.toArray(_APRRecordBuffer).vals()) { totalAPR += apr; };
            _avgAPR := Float.div(totalAPR, Float.fromInt(IntUtils.toInt(_APRRecordBuffer.size(), 512)));
          };
          case (#Err(code)) {
            _errorLogBuffer.add("Refund failed at " # debug_show (nowTime) # " . Code: " # debug_show (code) # ".");
          };
        };
      } catch (e) {
        _errorLogBuffer.add("Refund failed at " # debug_show (nowTime) # " . Msg: " # debug_show (Error.message(e)) # ".");
      };
    } else {
      await _farmIndexAct.updateFarmStatus(#CLOSED);
      await _farmIndexAct.updateFarmTVL({
        poolToken0 = { address = _TVL.poolToken0.address; standard = _TVL.poolToken0.standard; amount = 0; };
        poolToken1 = { address = _TVL.poolToken1.address; standard = _TVL.poolToken1.standard; amount = 0; };
      });
      await _farmIndexAct.updateUserInfo(Iter.toArray(_userPositionMap.keys()));
      _totalRewardBalance := 0;
      _status := #CLOSED;
      _TVL := {
        poolToken0 = { address = _TVL.poolToken0.address; standard = _TVL.poolToken0.standard; amount = 0; };
        poolToken1 = { address = _TVL.poolToken1.address; standard = _TVL.poolToken1.standard; amount = 0; };
      };
      var totalAPR : Float = 0;
      for ((time, apr) in Buffer.toArray(_APRRecordBuffer).vals()) { totalAPR += apr; };
      _avgAPR := Float.div(totalAPR, Float.fromInt(IntUtils.toInt(_APRRecordBuffer.size(), 512)));
    };

    return #ok("Close successfully");
  };

  public shared (msg) func setLimitInfo(token0Limit : Nat, token1Limit : Nat, positionNumLimit : Nat, priceInsideLimit : Bool) : async () {
    _checkAdminPermission(msg.caller);

    _token0AmountLimit := token0Limit;
    _token1AmountLimit := token1Limit;
    _positionNumLimit := positionNumLimit;
    _priceInsideLimit := priceInsideLimit;
  };

  public query func getRewardInfo(positionIds : [Nat]) : async Result.Result<Nat, Types.Error> {
    var reward = 0;
    for (id in positionIds.vals()) {
      switch (_depositMap.get(id)) {
        case (?deposit) { reward := reward + deposit.rewardAmount };
        case (_) {};
      };
    };
    return #ok(reward);
  };

  public query func getFarmInfo(user : Text) : async Result.Result<Types.FarmInfo, Types.Error> {
    var userPositionIds : Buffer.Buffer<Nat> = Buffer.Buffer<Nat>(0);
    if (not Text.equal(user, "")) {
      var userPrincipal = Principal.fromText(user);
      var currentPositionIdsList = switch (_userPositionMap.get(userPrincipal)) {
        case (?list) { list };
        case (_) { [] };
      };
      for (z in currentPositionIdsList.vals()) { userPositionIds.add(z) };
    } else {
      for (item in _positionIds.vals()) { userPositionIds.add(item) };
    };
    return #ok({
      rewardToken = initArgs.rewardToken;
      pool = initArgs.pool;
      poolToken0 = _poolToken0;
      poolToken1 = _poolToken1;
      poolFee = _poolFee;
      startTime = initArgs.startTime;
      endTime = initArgs.endTime;
      refunder = initArgs.refunder;
      totalReward = _totalReward;
      totalRewardBalance = _totalRewardBalance;
      totalRewardHarvested = _totalRewardHarvested;
      totalRewardUnharvested = _totalRewardUnharvested;
      farmCid = Principal.fromActor(this);
      status = _status;
      numberOfStakes = _positionIds.size();
      userNumberOfStakes = userPositionIds.size();
      positionIds = Buffer.toArray(userPositionIds);
      creator = initArgs.creator;
    });
  };

  public query func getUserDeposits(owner : Principal) : async Result.Result<[Types.Deposit], Types.Error> {
    switch (_userPositionMap.get(owner)) {
      case (?list) {
        var buffer = Buffer.Buffer<Types.Deposit>(0);
        for (positionId in list.vals()) {
          switch (_depositMap.get(positionId)) {
            case (?deposit) { buffer.add(deposit) };
            case (_) {};
          };
        };
        return #ok(Buffer.toArray(buffer));
      };
      case (_) {
        return #ok([]);
      };
    };
  };

  public query func getUserTVL(owner : Principal) : async Result.Result<{ poolToken0 : Types.TokenAmount; poolToken1 : Types.TokenAmount; }, Types.Error> {
    switch (_userPositionMap.get(owner)) {
      case (?list) {
        var poolToken0Amount : Int = 0;
        var poolToken1Amount : Int = 0;
        for (positionId in list.vals()) {
          switch (_depositMap.get(positionId)) {
            case (?deposit) {
              poolToken0Amount := deposit.token0Amount + poolToken0Amount;
              poolToken1Amount := deposit.token1Amount + poolToken1Amount;
            };
            case (_) {};
          };
        };
        return #ok(
          {
            poolToken0 = { address = _TVL.poolToken0.address; standard = _TVL.poolToken0.standard; amount = IntUtils.toNat(poolToken0Amount, 512); };
            poolToken1 = { address = _TVL.poolToken1.address; standard = _TVL.poolToken1.standard; amount = IntUtils.toNat(poolToken1Amount, 512); };
          }
        );
      };
      case (_) {
        return #ok(
          {
            poolToken0 = { address = _TVL.poolToken0.address; standard = _TVL.poolToken0.standard; amount = 0; };
            poolToken1 = { address = _TVL.poolToken1.address; standard = _TVL.poolToken1.standard; amount = 0; };
          }
        );
      };
    };
  };

  public query func getUserRewardBalance(owner : Principal) : async Result.Result<Nat, Types.Error> {
    return #ok(_rewardTokenHolderService.getBalance(owner));
  };
  
  public query func getUserRewardBalances(offset : Nat, limit : Nat) : async Result.Result<Types.Page<(Principal, Nat)>, Types.Error> {
    let resultArr : Buffer.Buffer<(Principal, Nat)> = Buffer.Buffer<(Principal, Nat)>(0);
    var begin : Nat = 0;
    label l {
      for ((principal, balance) in _rewardTokenHolderService.getAllBalances().entries()) {
        if (begin >= offset and begin < (offset + limit)) {
          resultArr.add((principal, balance));
        };
        if (begin >= (offset + limit)) { break l };
        begin := begin + 1;
      };
    };
    return #ok({
      totalElements = _rewardTokenHolderService.getAllBalances().size();
      content = Buffer.toArray(resultArr);
      offset = offset;
      limit = limit;
    });
  };

  public query func getPositionIds() : async Result.Result<[Nat], Types.Error> {
    return #ok(_positionIds);
  };

  public query func getLiquidityInfo() : async Result.Result<{ totalLiquidity : Nat; poolToken0Amount : Nat; poolToken1Amount : Nat }, Types.Error> {
    return #ok({
      totalLiquidity = _totalLiquidity;
      poolToken0Amount = _poolToken0Amount;
      poolToken1Amount = _poolToken1Amount;
    });
  };

  public query func getDeposit(positionId : Nat) : async Result.Result<Types.Deposit, Types.Error> {
    switch (_depositMap.get(positionId)) {
      case (?deposit) {
        return #ok(deposit);
      };
      case (_) {
        return #err(#InternalError("No such position"));
      };
    };
  };

  public query func getTVL() : async Result.Result<Types.TVL, Types.Error> {
    return #ok(_TVL);
  };

  public query func getAvgAPR() : async Result.Result<Float, Types.Error> {
    if (_avgAPR != 0) {
      return #ok(_avgAPR);
    } else {
      var totalAPR : Float = 0;
      if (_APRRecordBuffer.size() == 0) { return #ok(0); };
      for ((time, apr) in Buffer.toArray(_APRRecordBuffer).vals()) { totalAPR += apr; };
      return #ok(Float.div(totalAPR, Float.fromInt(IntUtils.toInt(_APRRecordBuffer.size(), 512))));
    };
  };

  public query func getAPRRecord() : async Result.Result<[(Nat, Float)], Types.Error> {
    return #ok(Buffer.toArray(_APRRecordBuffer));
  };

  public query func getAPRConst() : async Result.Result<{
    timeConst : Float;
    rewardTokenDecimalsConst : Float;
    token0DecimalsConst : Float;
    token1DecimalsConst : Float;
  }, Types.Error> {
    return #ok({
      timeConst = _timeConst;
      rewardTokenDecimalsConst = _rewardTokenDecimalsConst;
      token0DecimalsConst = _token0DecimalsConst;
      token1DecimalsConst = _token1DecimalsConst;
    });
  };

  public query func getInitArgs() : async Result.Result<Types.InitFarmArgs, Types.Error> {
    return #ok(initArgs);
  };

  public query func getLimitInfo() : async Result.Result<{ positionNumLimit : Nat; token0AmountLimit : Nat; token1AmountLimit : Nat; priceInsideLimit : Bool }, Types.Error> {
    return #ok({
      positionNumLimit = _positionNumLimit;
      token0AmountLimit = _token0AmountLimit;
      token1AmountLimit = _token1AmountLimit;
      priceInsideLimit = _priceInsideLimit;
    });
  };

  public query func getPoolTokenMeta() : async Result.Result<{
    poolToken0 : { address : Text; standard : Text; };
    poolToken1 : { address : Text; standard : Text; };
    poolToken0Symbol : Text;
    poolToken1Symbol : Text;
    poolToken0Decimals : Nat;
    poolToken1Decimals : Nat;
  }, Types.Error> {
    return #ok({
      poolToken0 = _poolToken0;
      poolToken1 = _poolToken1;
      poolToken0Symbol = _poolToken0Symbol;
      poolToken1Symbol = _poolToken1Symbol;
      poolToken0Decimals = _poolToken0Decimals;
      poolToken1Decimals = _poolToken1Decimals;
    });
  };

  public query func getRewardMeta() : async Result.Result<{ 
    totalReward : Nat; 
    totalRewardHarvested : Nat; 
    totalRewardUnharvested : Nat; 
    totalRewardBalance : Nat; 
    totalRewardFee : Nat; 
    secondPerCycle : Nat; 
    rewardPerCycle : Nat; 
    currentCycleCount : Nat; 
    totalCycleCount : Nat;
    rewardTokenFee : Nat;
    rewardTokenDecimals : Nat; 
  }, Types.Error> {
    return #ok({
      totalReward = _totalReward;
      totalRewardHarvested = _totalRewardHarvested;
      totalRewardUnharvested = _totalRewardUnharvested;
      totalRewardBalance = _totalRewardBalance;
      totalRewardFee = _totalRewardFee;
      secondPerCycle = initArgs.secondPerCycle;
      rewardPerCycle = _rewardPerCycle;
      currentCycleCount = _currentCycleCount;
      totalCycleCount = _totalCycleCount;
      rewardTokenFee = _rewardTokenFee;
      rewardTokenDecimals = _rewardTokenDecimals;
    });
  };

  public shared func getRewardTokenBalance() : async Nat {
    return await _rewardTokenAdapter.balanceOf({
      owner = Principal.fromActor(this);
      subaccount = null;
    });
  };

  public query func getPoolMeta() : async { sqrtPriceX96 : Nat; tick : Int; } {
    return {
      sqrtPriceX96 = _poolMetadata.sqrtPriceX96;
      tick = _poolMetadata.tick;
    };
  };

  public query func getTransferLogs() : async Result.Result<[Types.TransferLog], Types.Error> {
      return #ok(Iter.toArray(_transferLog.vals()));
  };

  public query func getStakeRecord(offset : Nat, limit : Nat, from : Text) : async Result.Result<Types.Page<Types.StakeRecord>, Text> {
    let size = _stakeRecordBuffer.size();
    if (size == 0) {
      return #ok({
        totalElements = 0;
        content = [];
        offset = offset;
        limit = limit;
      });
    };
    let stakeRecord = CollectionUtils.sort<Types.StakeRecord>(
      Buffer.toArray(_stakeRecordBuffer),
      func(x : Types.StakeRecord, y : Types.StakeRecord) : {
        #greater;
        #equal;
        #less;
      } {
        if (x.timestamp < y.timestamp) { #greater } else if (x.timestamp == y.timestamp) {
          #equal;
        } else { #less };
      },
    );
    var resultBuffer = Buffer.Buffer<Types.StakeRecord>(0);
    if (Text.notEqual("", from)) {
      let fromPrincipal = Principal.fromText(from);
      for (record in stakeRecord.vals()) {
        if (Principal.equal(fromPrincipal, record.from)) {
          resultBuffer.add(record);
        };
      };
    } else {
      for (record in stakeRecord.vals()) { resultBuffer.add(record) };
    };
    return #ok({
      totalElements = size;
      content = CollectionUtils.arrayRange<Types.StakeRecord>(Buffer.toArray(resultBuffer), offset, limit);
      offset = offset;
      limit = limit;
    });
  };

  public query func getDistributeRecord(offset : Nat, limit : Nat, owner : Text) : async Result.Result<Types.Page<Types.DistributeRecord>, Text> {
    let size = _distributeRecordBuffer.size();
    if (size == 0) {
      return #ok({
        totalElements = 0;
        content = [];
        offset = offset;
        limit = limit;
      });
    };
    let distributeRecord = CollectionUtils.sort<Types.DistributeRecord>(
      Buffer.toArray(_distributeRecordBuffer),
      func(x : Types.DistributeRecord, y : Types.DistributeRecord) : {
        #greater;
        #equal;
        #less;
      } {
        if (x.timestamp < y.timestamp) { #greater } else if (x.timestamp == y.timestamp) {
          #equal;
        } else { #less };
      },
    );
    var resultBuffer = Buffer.Buffer<Types.DistributeRecord>(0);
    if (Text.notEqual("", owner)) {
      let ownerPrincipal = Principal.fromText(owner);
      for (record in distributeRecord.vals()) {
        if (Principal.equal(ownerPrincipal, record.owner)) {
          resultBuffer.add(record);
        };
      };
    } else {
      for (record in distributeRecord.vals()) { resultBuffer.add(record) };
    };
    return #ok({
      totalElements = size;
      content = CollectionUtils.arrayRange<Types.DistributeRecord>(Buffer.toArray(resultBuffer), offset, limit);
      offset = offset;
      limit = limit;
    });
  };

  public shared func getCycleInfo() : async Result.Result<Types.CycleInfo, Types.Error> {
    return #ok({ balance = Cycles.balance(); available = Cycles.available() });
  };

  private func _updateRewardTokenFee() : async () {
    // Debug.print(" ---> _updateRewardTokenFee ");
    try {
      _rewardTokenFee := await _rewardTokenAdapter.fee();
    } catch (e) {
      _errorLogBuffer.add("_updateRewardTokenFee failed " # debug_show (Error.message(e)) # " . nowTime: " # debug_show (_getTime()));
    };
  };

  private func _updateStatus() : async () {
    // Debug.print(" ---> _updateStatus ");
    var nowTime = _getTime();
    // check balance
    if (_status == #NOT_STARTED) {
      switch (_canisterId) {
        case (?cid) {
          var balance = await _rewardTokenAdapter.balanceOf({
            owner = cid;
            subaccount = null;
          });
          if (balance < _totalReward) {
            _errorLogBuffer.add("_updateStatus failed: balance=" # debug_show (balance) # ", totalReward=" # debug_show (_totalReward) # ".");
            return;
          };
        };
        case (_) { return };
      };
    };

    if (_status != #CLOSED and _status != #FINISHED) {
      if (nowTime > initArgs.startTime and nowTime < initArgs.endTime) {
        _status := #LIVE;
      };
      if (nowTime < initArgs.startTime) { _status := #NOT_STARTED };
      if (nowTime > initArgs.endTime) { _status := #FINISHED };
    };
    if (_status == #FINISHED and (_totalRewardBalance == 0 and _positionIds.size() == 0)) {
      _status := #CLOSED;
    };
    await _farmIndexAct.updateFarmStatus(_status);
  };

  private func _updateUserInfo() : async () {
    // Debug.print(" ---> _updateUserInfo ");
    await _farmIndexAct.updateUserInfo(Iter.toArray(_userPositionMap.keys()));
  };

  private func _updateTVL() : async () {
    // Debug.print(" ---> _updateTVL ");
    await _farmIndexAct.updateFarmTVL(_TVL);
  };
  
  private func _updateAPR() : async () {
    if (_status == #FINISHED and _avgAPR == 0 ) {
      Debug.print(" ---> _updateAvgAPR ");
      var totalAPR : Float = 0;
      for ((time, apr) in Buffer.toArray(_APRRecordBuffer).vals()) { totalAPR += apr; };
      _avgAPR := Float.div(totalAPR, Float.fromInt(IntUtils.toInt(_APRRecordBuffer.size(), 512)));
    };
    if (_status != #LIVE) { return };
    try {
      Debug.print(" ---> _updateAPR ");
      let rewardTokenStorageCid = switch (await _nodeIndexAct.tokenStorage(initArgs.rewardToken.address)) {
        case (?cid) { cid };
        case (_) { _errorLogBuffer.add("_updateAPR get reward token storage cid failed. nowTime: " # debug_show (_getTime())); return; };
      };
      let token0StorageCid = switch (await _nodeIndexAct.tokenStorage(_poolToken0.address)) {
        case (?cid) { cid };
        case (_) { _errorLogBuffer.add("_updateAPR get token0 storage cid failed. nowTime: " # debug_show (_getTime())); return; };
      };
      let token1StorageCid = switch (await _nodeIndexAct.tokenStorage(_poolToken1.address)) {
        case (?cid) { cid };
        case (_) { _errorLogBuffer.add("_updateAPR get token1 storage cid failed. nowTime: " # debug_show (_getTime())); return;
        };
      };
      let rewardTokenStorageAct = actor (rewardTokenStorageCid) : Types.ITokenStorage;
      let token0StorageAct = actor (token0StorageCid) : Types.ITokenStorage;
      let token1StorageAct = actor (token1StorageCid) : Types.ITokenStorage;
      let rewardTokenPriceUSD = (await rewardTokenStorageAct.getToken(initArgs.rewardToken.address)).priceUSD;
      let token0PriceUSD = (await token0StorageAct.getToken(_poolToken0.address)).priceUSD;
      let token1PriceUSD = (await token1StorageAct.getToken(_poolToken1.address)).priceUSD;

      // (Reward token amount each cycles * reward token price / Total valued staked) * (360 * 24 * 3600 / seconds each cycle) * 100%
      let rewardTokenAmount = Float.div(Float.fromInt(IntUtils.toInt(_rewardPerCycle, 512)), _rewardTokenDecimalsConst);
      let rewardTokenUSDValue = Float.mul(rewardTokenAmount, rewardTokenPriceUSD);
      let token0Amount = Float.div(Float.fromInt(IntUtils.toInt(_TVL.poolToken0.amount, 512)), _token0DecimalsConst);
      let token1Amount = Float.div(Float.fromInt(IntUtils.toInt(_TVL.poolToken1.amount, 512)), _token1DecimalsConst);
      let tvlUSD = Float.mul(token0Amount, token0PriceUSD) + Float.mul(token1Amount, token1PriceUSD);
      var apr =  100 * (rewardTokenUSDValue / tvlUSD) * (_timeConst / Float.fromInt(IntUtils.toInt(initArgs.secondPerCycle, 512)));
      
      _APRRecordBuffer.add((_getTime(), apr));
    } catch (e) {
      _errorLogBuffer.add("_updateAPR failed " # debug_show (Error.message(e)) # " . nowTime: " # debug_show (_getTime()));
    };
  };

  private func _syncPoolMeta() : async () {
    // Debug.print(" ---> _syncPoolMeta ");
    try {
      _poolMetadata := switch (await _swapPoolAct.metadata()) {
        case (#ok(poolMetadata)) { poolMetadata };
        case (#err(code)) {
          _errorLogBuffer.add("_syncPoolMeta failed " # debug_show (code) # " . nowTime: " # debug_show (_getTime()));
          return;
        };
      };
    } catch (e) {
      _errorLogBuffer.add("_syncPoolMeta failed " # debug_show (Error.message(e)) # " . nowTime: " # debug_show (_getTime()));
    };
  };

  private func _distributeFee(rewardAmount : Nat) : {
    rewardRedistribution : Nat;
    rewardFee : Nat;
  } {
    var rewardFee = SafeUint.Uint256(rewardAmount).mul(SafeUint.Uint256(initArgs.fee)).div(SafeUint.Uint256(1000)).val();
    var rewardRedistribution = if (rewardAmount > rewardFee) {
      SafeUint.Uint128(rewardAmount).sub(SafeUint.Uint128(rewardFee)).val();
    } else { rewardFee := 0; rewardAmount };
    return {
      rewardRedistribution = rewardRedistribution;
      rewardFee = rewardFee;
    };
  };

  private stable var _lastDistributionNum : Nat = 0;
  private func _distributeReward() : async () {
    try {
      // Debug.print(" ---> _distributeReward ");
      var currentTime = _getTime();
      if (currentTime < initArgs.startTime) { return };
      if (_status != #LIVE) { return };

      var currentCycleTime = initArgs.startTime + initArgs.secondPerCycle * (_currentCycleCount + 1);
      var timeReached = if (currentTime < (currentCycleTime + 30) and (currentTime + 30) > currentCycleTime) {
        true;
      } else {
        if ((currentTime - initArgs.startTime) / initArgs.secondPerCycle > _lastDistributionNum) {
          _lastDistributionNum := (currentTime - initArgs.startTime) / initArgs.secondPerCycle;
          true;
        } else {
          false;
        };
      };
      if (not timeReached) {
        _errorLogBuffer.add("current time does not reach the distribution time: " # debug_show (currentTime));
        return;
      };

      var totalWeightedRatio : Nat = 0;
      var depositMap = HashMap.fromIter<Nat, Types.Deposit>(Iter.toArray(_depositMap.entries()).vals(), 100, Types.equal, Types.hash);

      for ((id, deposit) in depositMap.entries()) {
        if ((_priceInsideLimit and (_poolMetadata.tick <= deposit.tickUpper and _poolMetadata.tick >= deposit.tickLower)) or (not _priceInsideLimit)) {
          if (Nat.equal(deposit.lastDistributeTime, 0)) {
            totalWeightedRatio := totalWeightedRatio + deposit.liquidity * (currentTime - deposit.initTime);
          } else {
            totalWeightedRatio := totalWeightedRatio + deposit.liquidity * (currentTime - deposit.lastDistributeTime);
          };
        };
      };
      // Debug.print("totalWeightedRatio: " # debug_show (totalWeightedRatio));

      var poolToken0Amount : Int = 0;
      var poolToken1Amount : Int = 0;
      for ((id, deposit) in depositMap.entries()) {
        let amountResult = switch (_getTokenAmountByLiquidity(deposit.tickLower, deposit.tickUpper, deposit.liquidity)) {
          case (#ok(result)) { result };
          case (#err(msg)) { { amount0 = 0; amount1 = 0 } };
        };
        poolToken0Amount := poolToken0Amount + amountResult.amount0;
        poolToken1Amount := poolToken1Amount + amountResult.amount1;
        var rewardAmount : Nat = 0;
        if ((_priceInsideLimit and (_poolMetadata.tick <= deposit.tickUpper and _poolMetadata.tick >= deposit.tickLower)) or (not _priceInsideLimit)) {
          rewardAmount := if (Nat.equal(deposit.lastDistributeTime, 0)) {
            _computeReward(deposit.liquidity * (currentTime - deposit.initTime), totalWeightedRatio);
          } else {
            _computeReward(deposit.liquidity * (currentTime - deposit.lastDistributeTime), totalWeightedRatio);  
          };
          // distribute reward record
          _distributeRecordBuffer.add({
            timestamp = currentTime;
            positionId = id;
            owner = deposit.owner;
            rewardGained = rewardAmount;
            rewardTotal = _rewardPerCycle;
          });
        };
        _depositMap.put(
          id,
          {
            owner = deposit.owner;
            holder = deposit.holder;
            positionId = deposit.positionId;
            tickLower = deposit.tickLower;
            tickUpper = deposit.tickUpper;
            rewardAmount = deposit.rewardAmount + rewardAmount;
            liquidity = deposit.liquidity;
            initTime = deposit.initTime;
            lastDistributeTime = currentTime;
            token0Amount = amountResult.amount0;
            token1Amount = amountResult.amount1;
          },
        );
      };
      _currentCycleCount := _currentCycleCount + 1;
      _poolToken0Amount := IntUtils.toNat(poolToken0Amount, 512);
      _poolToken1Amount := IntUtils.toNat(poolToken1Amount, 512);
      // update TVL
      _TVL := {
        poolToken0 = { address = _TVL.poolToken0.address; standard = _TVL.poolToken0.standard; amount = _poolToken0Amount; };
        poolToken1 = { address = _TVL.poolToken1.address; standard = _TVL.poolToken1.standard; amount = _poolToken1Amount; };
      };
    } catch (e) {
      _errorLogBuffer.add("_distributeReward failed " # debug_show (Error.message(e)) # " . nowTime: " # debug_show (_getTime()));
    };
  };

  private func _computeReward(weightedRatio : Nat, totalWeightedRatio : Nat) : Nat {
    var excessDecimal = SafeUint.Uint512(100000000);
    var weightedRatioXe8 = SafeUint.Uint512(weightedRatio).mul(excessDecimal);
    var rate = if (totalWeightedRatio == 0) { SafeUint.Uint512(0) } else {
      weightedRatioXe8.div(SafeUint.Uint512(totalWeightedRatio));
    };
    var reward = SafeUint.Uint512(_rewardPerCycle).mul(rate).div(excessDecimal).val();

    _totalRewardUnharvested := _totalRewardUnharvested + reward;
    _totalRewardBalance := _totalRewardBalance - reward;
    return reward;
  };

  private func _getTokenAmountByLiquidity(
    tickLower : Int,
    tickUpper : Int,
    liquidity : Nat,
  ) : Result.Result<{ amount0 : Int; amount1 : Int }, Text> {
    var sqrtRatioAtTickLower = switch (TickMath.getSqrtRatioAtTick(SafeInt.Int24(tickLower))) {
      case (#ok(result)) { result };
      case (#err(code)) {
        return #err("TickMath.getSqrtRatioAtTickLower failed: " # debug_show (code));
      };
    };
    var sqrtRatioAtTickUpper = switch (TickMath.getSqrtRatioAtTick(SafeInt.Int24(tickUpper))) {
      case (#ok(result)) { result };
      case (#err(code)) {
        return #err("TickMath.getSqrtRatioAtTickUpper failed: " # debug_show (code));
      };
    };
    var amount0 : Int = 0;
    var amount1 : Int = 0;
    if (liquidity != 0) {
      if (_poolMetadata.tick < tickLower) {
        amount0 := switch (SqrtPriceMath.getAmount0Delta(SafeUint.Uint160(sqrtRatioAtTickLower), SafeUint.Uint160(sqrtRatioAtTickUpper), SafeInt.Int128(liquidity))) {
          case (#ok(result)) { result };
          case (#err(code)) {
            return #err("SqrtPriceMath.getAmount0Delta 1 failed: " # debug_show (code));
          };
        };
      } else if (_poolMetadata.tick < tickUpper) {
        amount0 := switch (SqrtPriceMath.getAmount0Delta(SafeUint.Uint160(_poolMetadata.sqrtPriceX96), SafeUint.Uint160(sqrtRatioAtTickUpper), SafeInt.Int160(liquidity))) {
          case (#ok(result)) { result };
          case (#err(code)) {
            return #err("SqrtPriceMath.getAmount0Delta 2 failed: " # debug_show (code));
          };
        };
        amount1 := switch (SqrtPriceMath.getAmount1Delta(SafeUint.Uint160(sqrtRatioAtTickLower), SafeUint.Uint160(_poolMetadata.sqrtPriceX96), SafeInt.Int128(liquidity))) {
          case (#ok(result)) { result };
          case (#err(code)) {
            return #err("SqrtPriceMath.getAmount1Delta 3 failed: " # debug_show (code));
          };
        };
      } else {
        amount1 := switch (SqrtPriceMath.getAmount1Delta(SafeUint.Uint160(sqrtRatioAtTickLower), SafeUint.Uint160(sqrtRatioAtTickUpper), SafeInt.Int128(liquidity))) {
          case (#ok(result)) { result };
          case (#err(code)) {
            return #err("SqrtPriceMath.getAmount1Delta 4 failed: " # debug_show (code));
          };
        };
      };
    };
    return #ok({ amount0 = amount0; amount1 = amount1 });
  };

  private func _getTime() : Nat {
    return IntUtils.toNat(Time.now() / 1000000000, 256);
  };

  private func _natToBlob(x: Nat): Blob {
    let arr: [Nat8] = _fromNat(8, x);
    return Blob.fromArray(arr);
  };

  private func _fromNat(len : Nat, n : Nat) : [Nat8] {
    let ith_byte = func(i : Nat) : Nat8 {
      assert(i < len);
      let shift : Nat = 8 * (len - 1 - i);
      Nat8.fromIntWrap(n / 2 ** shift)
    };
    return Array.tabulate<Nat8>(len, ith_byte);
  };

  // --------------------------- ACL ------------------------------------
  private stable var _admins : [Principal] = [];
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
    return Prim.isController(caller) or (switch (initArgs.governanceCid) { case (?cid) { Principal.equal(caller, cid) }; case (_) { false } });
  };

  // --------------------------- ERROR LOG ------------------------------------
  private stable var _errorLogList : [Text] = [];
  private var _errorLogBuffer : Buffer.Buffer<Text> = Buffer.Buffer<Text>(0);
  public shared (msg) func clearErrorLog() : async () {
    _checkAdminPermission(msg.caller);
    _errorLogBuffer := Buffer.Buffer<Text>(0);
  };
  public query func getErrorLog() : async [Text] {
    return Buffer.toArray(_errorLogBuffer);
  };

  // --------------------------- ERROR LOG ------------------------------------
  private let NANOSECONDS_PER_SECOND : Nat = 1_000_000_000;
  private let SECOND_PER_DAY : Nat = 86400;
  private stable var _transferLogArray : [(Nat, Types.TransferLog)] = [];
  private stable var _transferIndex: Nat = 0;
  private var _transferLog: HashMap.HashMap<Nat, Types.TransferLog> = HashMap.fromIter<Nat, Types.TransferLog>(_transferLogArray.vals(), 0, Nat.equal, Hash.hash);
  private func _preTransfer(owner: Principal, from: Principal, fromSubaccount: ?Blob, to: Principal, action: Text, token: Types.Token, amount: Nat, fee: Nat): Nat {
    let time: Nat = Int.abs(Time.now());
    let ind: Nat = _transferIndex;
    let transferLog: Types.TransferLog = {
      index = ind;
      owner = owner;
      from = from;
      fromSubaccount = fromSubaccount;
      to = to;
      action = action;
      amount = amount;
      fee = fee;
      token = token;
      result = "processing";
      errorMsg = "";
      daysFrom19700101 = time / NANOSECONDS_PER_SECOND / SECOND_PER_DAY;
      timestamp = time;
    };
    _transferLog.put(ind, transferLog);
    _transferIndex := _transferIndex + 1;
    return ind;
  };
  private func _postTransferComplete(index: Nat) {
    _transferLog.delete(index);
  };
  private func _postTransferError(index: Nat, msg: Text) {
    switch(_transferLog.get(index)) {
      case (?log) {
        _transferLog.put(index, {
          index = log.index;
          owner = log.owner;
          from = log.from;
          fromSubaccount = log.fromSubaccount;
          to = log.to;
          action = log.action;
          amount = log.amount;
          fee = log.fee;
          token = log.token;
          result = "error";
          errorMsg = msg;
          daysFrom19700101 = log.daysFrom19700101;
          timestamp = log.timestamp;
        });
      };
      case (_) {};
    };
  };

  // --------------------------- SCHEDULE ------------------------------------
  let _distributeRewardPerCycle = Timer.recurringTimer<system>(#seconds(initArgs.secondPerCycle), _distributeReward);
  let _syncPoolMetaPer60s = Timer.recurringTimer<system>(#seconds(60), _syncPoolMeta);
  let _updateStatusPer60s = Timer.recurringTimer<system>(#seconds(60), _updateStatus);
  let _updateTVLPer10m = Timer.recurringTimer<system>(#seconds(600), _updateTVL);
  let _updateRewardTokenFeePer1h = Timer.recurringTimer<system>(#seconds(3600), _updateRewardTokenFee);
  let _updateAPRPer30m = Timer.recurringTimer<system>(#seconds(1800), _updateAPR);
  
  // for testing
  // let _distributeRewardPerCycle = Timer.recurringTimer<system>(#seconds(initArgs.secondPerCycle), _distributeReward);
  // let _syncPoolMetaPer60s = Timer.recurringTimer<system>(#seconds(10), _syncPoolMeta);
  // let _updateStatusPer60s = Timer.recurringTimer<system>(#seconds(10), _updateStatus);
  // let _updateTVLPer10m = Timer.recurringTimer<system>(#seconds(10), _updateTVL);
  // let _updateRewardTokenFeePer1h = Timer.recurringTimer<system>(#seconds(10), _updateRewardTokenFee);
  // let _updateAPRPer30m = Timer.recurringTimer<system>(#seconds(10), _updateAPR);
  // --------------------------- Version Control ------------------------------------
  private var _version : Text = "3.2.0";
  public query func getVersion() : async Text { _version };

  // --------------------------- LIFE CYCLE -----------------------------------
  system func preupgrade() {
    _userPositionEntries := Iter.toArray(_userPositionMap.entries());
    _depositEntries := Iter.toArray(_depositMap.entries());
    _errorLogList := Buffer.toArray(_errorLogBuffer);
    _stakeRecordList := Buffer.toArray(_stakeRecordBuffer);
    _distributeRecordList := Buffer.toArray(_distributeRecordBuffer);
    _APRRecordList := Buffer.toArray(_APRRecordBuffer);
    _rewardTokenHolderState := _rewardTokenHolderService.getState();
  };

  system func postupgrade() {
    for (record in _errorLogList.vals()) { _errorLogBuffer.add(record) };
    for (record in _stakeRecordList.vals()) { _stakeRecordBuffer.add(record) };
    for (record in _distributeRecordList.vals()) { _distributeRecordBuffer.add(record); };
    for (record in _APRRecordList.vals()) { _APRRecordBuffer.add(record); };
    _stakeRecordList := [];
    _distributeRecordList := [];
    _errorLogList := [];
    _APRRecordList := [];
    _depositEntries := [];
    _userPositionEntries := [];
  };

  system func inspect({
    arg : Blob;
    caller : Principal;
    msg : Types.FarmMsg;
  }) : Bool {
    return switch (msg) {
      // Controller
      case (#init args)                       { _hasPermission(caller) };
      case (#setAdmins args)                  { _hasPermission(caller) };
      // Admin
      case (#close args)                      { _hasAdminPermission(caller) };
      case (#clearErrorLog args)              { _hasAdminPermission(caller) };
      case (#finishManually args)             { _hasAdminPermission(caller) };
      case (#removeErrorTransferLog args)     { _hasAdminPermission(caller) };
      case (#restartManually args)            { _hasAdminPermission(caller) };
      case (#sendRewardManually args)         { _hasAdminPermission(caller) };
      case (#setLimitInfo args)               { _hasAdminPermission(caller) };
      case (#withdrawRewardFee args)          { Principal.equal(caller, initArgs.feeReceiverCid); };
      // Anyone
      case (_)                                { true };
    };
  };

};
