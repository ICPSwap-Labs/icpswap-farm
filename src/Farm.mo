import Array "mo:base/Array";
import Buffer "mo:base/Buffer";
import Cycles "mo:base/ExperimentalCycles";
import Error "mo:base/Error";
import Debug "mo:base/Debug";
import Float "mo:base/Float";
import Nat8 "mo:base/Nat8";
import HashMap "mo:base/HashMap";
import Int "mo:base/Int";
import Iter "mo:base/Iter";
import List "mo:base/List";
import Time "mo:base/Time";
import Timer "mo:base/Timer";
import Nat "mo:base/Nat";
import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Text "mo:base/Text";
import CollectionUtils "mo:commons/utils/CollectionUtils";
import IntUtils "mo:commons/math/SafeInt/IntUtils";
import SafeUint "mo:commons/math/SafeUint";
import SafeInt "mo:commons/math/SafeInt";
import TokenFactory "mo:token-adapter/TokenFactory";
import Types "./Types";
import Prim "mo:⛔";
import SqrtPriceMath "mo:icpswap-v3-service/libraries/SqrtPriceMath";
import TickMath "mo:icpswap-v3-service/libraries/TickMath";

shared (initMsg) actor class Farm(
  initArgs : Types.InitFarmArgs
) = this {

  private stable var _canisterId : ?Principal = null;
  private stable var _ICPDecimals : Nat = 0;

  // reward meta
  private stable var _status : Types.FarmStatus = #NOT_STARTED;
  private stable var _rewardPerCycle : Nat = 0;
  private stable var _currentCycleCount : Nat = 0;
  private stable var _totalCycleCount : Nat = 0;
  private stable var _totalReward = initArgs.totalReward;
  private stable var _totalRewardBalance = initArgs.totalReward;
  private stable var _totalRewardClaimed = 0;
  private stable var _totalRewardUnclaimed = 0;
  private stable var _totalRewardFee = 0;
  private stable var _totalLiquidity = 0;
  private stable var _TVL = {
    var stakedTokenTVL : Float = 0;
    var rewardTokenTVL : Float = 0;
  };

  // position pool metadata
  private stable var _poolToken0 = { address = ""; standard = "" };
  private stable var _poolToken1 = { address = ""; standard = "" };
  private stable var _poolToken0Fee = 0;
  private stable var _poolToken1Fee = 0;
  private stable var _poolToken0Amount = 0;
  private stable var _poolToken1Amount = 0;
  private stable var _poolToken0Decimals : Nat = 0;
  private stable var _poolToken1Decimals : Nat = 0;
  private stable var _poolFee : Nat = 0;
  private stable var _poolZeroForOne = false;
  private stable var _poolMetadata = {
    sqrtPriceX96 : Nat = 0;
    tick : Int = 0;
    toICPPrice : Float = 0;
  };

  // reward pool metadata
  private stable var _rewardTokenDecimals : Nat = 0;
  private stable var _rewardPoolZeroForOne = false;
  private stable var _rewardPoolMetadata = {
    sqrtPriceX96 : Nat = 0;
    tick : Int = 0;
    toICPPrice : Float = 0;
  };

  // limit params
  private stable var _positionNumLimit : Nat = 500;
  private stable var _token0AmountLimit : Nat = initArgs.token0AmountLimit;
  private stable var _token1AmountLimit : Nat = initArgs.token0AmountLimit;
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

  let _ICPAdapter = TokenFactory.getAdapter(initArgs.ICP.address, initArgs.ICP.standard);
  let _rewardTokenAdapter = TokenFactory.getAdapter(initArgs.rewardToken.address, initArgs.rewardToken.standard);
  private stable var _swapPoolAct = actor (Principal.toText(initArgs.pool)) : actor {
    batchRefreshIncome : query (positionIds : [Nat]) -> async Result.Result<{ totalTokensOwed0 : Nat; totalTokensOwed1 : Nat; tokenIncome : [(Nat, { tokensOwed0 : Nat; tokensOwed1 : Nat })] }, Types.Error>;
    quote : query (args : Types.SwapArgs) -> async Result.Result<Nat, Types.Error>;
    metadata : query () -> async Result.Result<Types.PoolMetadata, Types.Error>;
    getUserPosition : query (positionId : Nat) -> async Result.Result<Types.UserPositionInfo, Types.Error>;
    transferPosition : shared (from : Principal, to : Principal, positionId : Nat) -> async Result.Result<Bool, Types.Error>;
    refreshIncome : query (positionId : Nat) -> async Result.Result<{ tokensOwed0 : Nat; tokensOwed1 : Nat }, Types.Error>;
  };
  private stable var _rewardPoolAct = actor (Principal.toText(initArgs.rewardPool)) : actor {
    quote : query (args : Types.SwapArgs) -> async Result.Result<Nat, Types.Error>;
    metadata : query () -> async Result.Result<Types.PoolMetadata, Types.Error>;
  };
  private stable var _farmControllerAct = actor (Principal.toText(initArgs.farmControllerCid)) : actor {
    updateFarmInfo : shared (status : Types.FarmStatus, tvl : Types.TVL) -> async ();
  };

  private stable var _inited : Bool = false;
  private stable var _initLock : Bool = false;
  public shared (msg) func init() : async () {
    _checkPermission(msg.caller);

    assert (not _inited);
    assert (not _initLock);
    _initLock := true;

    _canisterId := ?Principal.fromActor(this);
    var tempRewardTotalCount = SafeUint.Uint512(initArgs.endTime).sub(SafeUint.Uint512(initArgs.startTime)).div(SafeUint.Uint512(initArgs.secondPerCycle)).add(SafeUint.Uint512(1));
    _totalCycleCount := tempRewardTotalCount.val();
    _rewardPerCycle := SafeUint.Uint512(_totalReward).div(tempRewardTotalCount).val();

    let rewardPoolMetadata = switch (await _rewardPoolAct.metadata()) {
      case (#ok(poolMetadata)) { poolMetadata };
      case (#err(code)) {
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
    _rewardPoolZeroForOne := if (Text.equal(initArgs.ICP.address, rewardPoolMetadata.token0.address)) {
      false;
    } else { true };
    let poolMetadata = switch (await _swapPoolAct.metadata()) {
      case (#ok(poolMetadata)) { poolMetadata };
      case (#err(code)) {
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
    _poolZeroForOne := if (Text.equal(initArgs.ICP.address, _poolToken0.address)) {
      false;
    } else { true };

    _ICPDecimals := Nat8.toNat(await _ICPAdapter.decimals());
    _rewardTokenDecimals := Nat8.toNat(await _rewardTokenAdapter.decimals());
    let poolToken0Adapter = TokenFactory.getAdapter(_poolToken0.address, _poolToken0.standard);
    let poolToken1Adapter = TokenFactory.getAdapter(_poolToken1.address, _poolToken1.standard);
    _poolToken0Decimals := Nat8.toNat(await poolToken0Adapter.decimals());
    _poolToken1Decimals := Nat8.toNat(await poolToken1Adapter.decimals());
    _poolToken0Fee := await poolToken0Adapter.fee();
    _poolToken1Fee := await poolToken1Adapter.fee();
    _rewardPoolMetadata := {
      sqrtPriceX96 = rewardPoolMetadata.sqrtPriceX96;
      tick = rewardPoolMetadata.tick;
      toICPPrice = _computeToICPPrice(
        if (_rewardPoolZeroForOne) { _rewardTokenDecimals } else {
          _ICPDecimals;
        },
        if (_rewardPoolZeroForOne) { _ICPDecimals } else {
          _rewardTokenDecimals;
        },
        rewardPoolMetadata.sqrtPriceX96,
        _rewardPoolZeroForOne,
      );
    };
    _poolMetadata := {
      sqrtPriceX96 = poolMetadata.sqrtPriceX96;
      tick = poolMetadata.tick;
      toICPPrice = _computeToICPPrice(_poolToken0Decimals, _poolToken1Decimals, poolMetadata.sqrtPriceX96, _poolZeroForOne);
    };

    _inited := true;
    _initLock := false;
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
      case (#err(msg)) { { amount0 = 0; amount1 = 0 } };
    };
    if (_token0AmountLimit != 0 and positionTokenAmounts.amount0 < _token0AmountLimit) {
      return #err(#InternalError("The quantity of token0 does not reach the low limit"));
    };
    if (_token1AmountLimit != 0 and positionTokenAmounts.amount1 < _token1AmountLimit) {
      return #err(#InternalError("The quantity of token1 does not reach the low limit"));
    };
    if (_token0AmountLimit != 0 and _token1AmountLimit != 0) {
      if (positionTokenAmounts.amount0 < _token0AmountLimit) {
        return #err(#InternalError("The quantity of token0 does not reach the low limit"));
      };
      if (positionTokenAmounts.amount1 < _token1AmountLimit) {
        return #err(#InternalError("The quantity of token1 does not reach the low limit"));
      };
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
            token0Amount = positionTokenAmounts.amount0;
            token1Amount = positionTokenAmounts.amount1;
          },
        );

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

    var fee = await _rewardTokenAdapter.fee();
    switch (await _swapPoolAct.transferPosition(Principal.fromActor(this), deposit.owner, positionId)) {
      case (#ok(status)) {
        let distributedFeeResult = _distributeFee(deposit.rewardAmount);
        if (distributedFeeResult.rewardRedistribution > fee) {
          var amount = distributedFeeResult.rewardRedistribution - fee;
          try {
            switch (await _rewardTokenAdapter.transfer({ from = { owner = Principal.fromActor(this); subaccount = null }; from_subaccount = null; to = { owner = deposit.owner; subaccount = null }; amount = amount; fee = ?fee; memo = null; created_at_time = null })) {
              case (#Ok(index)) {};
              case (#Err(code)) {
                _errorLogBuffer.add("Pay reward failed at " # debug_show (nowTime) # ". Code: " # debug_show (code) # ". Deposit info: " # debug_show (deposit));
              };
            };
          } catch (e) {
            _errorLogBuffer.add("Pay reward failed at " # debug_show (nowTime) # ". Msg: " # debug_show (Error.message(e)) # ". Deposit info: " # debug_show (deposit));
          };
        };
        _totalRewardUnclaimed := _totalRewardUnclaimed - deposit.rewardAmount;
        _totalRewardClaimed := _totalRewardClaimed + distributedFeeResult.rewardRedistribution;
        _totalRewardFee := _totalRewardFee + distributedFeeResult.rewardFee;
        _totalLiquidity := _totalLiquidity - deposit.liquidity;
        // unstake reward record
        _stakeRecordBuffer.add({
          timestamp = nowTime;
          transType = #unstake;
          positionId = positionId;
          from = Principal.fromActor(this);
          to = deposit.owner;
          amount = deposit.rewardAmount;
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

        return #ok("Unstaked successfully");
      };
      case (msg) {
        return #err(#InternalError("Transfer position failed: " # debug_show (msg)));
      };
    };
  };

  public shared (msg) func finishManually() : async Result.Result<Text, Types.Error> {
    _checkAdminPermission(msg.caller);
    _status := #FINISHED;
    await _farmControllerAct.updateFarmInfo(
      _status,
      {
        stakedTokenTVL = _TVL.stakedTokenTVL;
        rewardTokenTVL = _TVL.rewardTokenTVL;
      },
    );
    return #ok("Finish farm successfully");
  };

  public shared (msg) func restartManually() : async Result.Result<Text, Types.Error> {
    _checkAdminPermission(msg.caller);
    _status := #LIVE;
    await _farmControllerAct.updateFarmInfo(
      _status,
      {
        stakedTokenTVL = _TVL.stakedTokenTVL;
        rewardTokenTVL = _TVL.rewardTokenTVL;
      },
    );
    return #ok("Restart farm successfully");
  };

  public shared (msg) func withdrawRewardFee() : async Result.Result<Text, Types.Error> {
    assert (Principal.equal(msg.caller, initArgs.feeReceiverCid));

    var nowTime = _getTime();
    var fee = await _rewardTokenAdapter.fee();

    if (_totalRewardFee > fee) {
      let totalRewardFee = _totalRewardFee;
      var amount = _totalRewardFee - fee;
      try {
        switch (await _rewardTokenAdapter.transfer({ from = { owner = Principal.fromActor(this); subaccount = null }; from_subaccount = null; to = { owner = initArgs.feeReceiverCid; subaccount = null }; amount = amount; fee = ?fee; memo = null; created_at_time = null })) {
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
            return #ok("Withdraw successfully");
          };
          case (#Err(code)) {
            _errorLogBuffer.add("Withdraw failed at " # debug_show (nowTime) # " . code: " # debug_show (code) # ".");
            return #err(#InternalError("Withdraw failed at " # debug_show (nowTime) # " . code: " # debug_show (code) # "."));
          };
        };
      } catch (e) {
        _errorLogBuffer.add("Withdraw failed at " # debug_show (nowTime) # " . Msg: " # debug_show (Error.message(e)) # ".");
        return #err(#InternalError("Withdraw failed at " # debug_show (nowTime) # " . Msg: " # debug_show (Error.message(e)) # "."));
      };
    } else {
      return #err(#InternalError("Withdraw failed: InsufficientFunds."));
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

    var nowTime = _getTime();
    var previousStatus = _status;
    var fee = await _rewardTokenAdapter.fee();
    var balance = await _rewardTokenAdapter.balanceOf({
      owner = Principal.fromActor(this);
      subaccount = null;
    });
    if (balance <= _totalRewardBalance) {
      _errorLogBuffer.add("InsufficientFunds. balance: " # debug_show (balance) # " totalRewardBalance: " # debug_show (_totalRewardBalance) # " . nowTime: " # debug_show (nowTime));
    };

    Timer.cancelTimer(_distributeRewardPerCycle);
    Timer.cancelTimer(_syncPoolMetaPer60s);
    Timer.cancelTimer(_updateStatusPer60s);

    if (balance > fee) {
      var amount = balance - fee;
      try {
        switch (await _rewardTokenAdapter.transfer({ from = { owner = Principal.fromActor(this); subaccount = null }; from_subaccount = null; to = { owner = initArgs.refunder; subaccount = null }; amount = amount; fee = ?fee; memo = null; created_at_time = null })) {
          case (#Ok(index)) {
            await _farmControllerAct.updateFarmInfo(
              #CLOSED,
              {
                stakedTokenTVL = 0;
                rewardTokenTVL = 0;
              },
            );
            _stakeRecordBuffer.add({
              timestamp = nowTime;
              transType = #claim;
              positionId = 0;
              from = Principal.fromActor(this);
              to = initArgs.refunder;
              amount = amount;
              liquidity = 0;
            });
            _totalRewardBalance := 0;
            _status := #CLOSED;
            _TVL.stakedTokenTVL := 0;
            _TVL.rewardTokenTVL := 0;
          };
          case (#Err(code)) {
            _errorLogBuffer.add("Refund failed at " # debug_show (nowTime) # " . code: " # debug_show (code) # ".");
          };
        };
      } catch (e) {
        _errorLogBuffer.add("Refund failed at " # debug_show (nowTime) # " . Msg: " # debug_show (Error.message(e)) # ".");
      };
    } else {
      await _farmControllerAct.updateFarmInfo(
        #CLOSED,
        {
          stakedTokenTVL = 0;
          rewardTokenTVL = 0;
        },
      );
      _totalRewardBalance := 0;
      _status := #CLOSED;
      _TVL.stakedTokenTVL := 0;
      _TVL.rewardTokenTVL := 0;
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
      totalRewardClaimed = _totalRewardClaimed;
      totalRewardUnclaimed = _totalRewardUnclaimed;
      farmCid = Principal.fromActor(this);
      status = _status;
      numberOfStakes = _positionIds.size();
      userNumberOfStakes = userPositionIds.size();
      positionIds = Buffer.toArray(userPositionIds);
      creator = initArgs.creator;
      stakedTokenTVL = _TVL.stakedTokenTVL;
      rewardTokenTVL = _TVL.rewardTokenTVL;
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
        return #err(#InternalError("No position deposited"));
      };
    };
  };

  public query func getUserTVL(owner : Principal) : async Result.Result<Float, Types.Error> {
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
          if (_poolZeroForOne) {
            Float.add(
              Float.mul(
                Float.div(Float.fromInt(poolToken0Amount), Float.fromInt(SafeInt.Int256(10 ** _poolToken0Decimals).val())),
                _poolMetadata.toICPPrice,
              ),
              Float.div(Float.fromInt(poolToken1Amount), Float.fromInt(SafeInt.Int256(10 ** _poolToken1Decimals).val())),
            );
          } else {
            Float.add(
              Float.mul(
                Float.div(Float.fromInt(poolToken1Amount), Float.fromInt(SafeInt.Int256(10 ** _poolToken1Decimals).val())),
                _poolMetadata.toICPPrice,
              ),
              Float.div(Float.fromInt(poolToken0Amount), Float.fromInt(SafeInt.Int256(10 ** _poolToken0Decimals).val())),
            );
          }
        );
      };
      case (_) {
        return #ok(0);
      };
    };
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

  public query func getTVL() : async Result.Result<{ stakedTokenTVL : Float; rewardTokenTVL : Float }, Types.Error> {
    return #ok({
      stakedTokenTVL = _TVL.stakedTokenTVL;
      rewardTokenTVL = _TVL.rewardTokenTVL;
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

  public query func getRewardMeta() : async Result.Result<{ totalReward : Nat; totalRewardClaimed : Nat; totalRewardUnclaimed : Nat; totalRewardBalance : Nat; totalRewardFee : Nat; secondPerCycle : Nat; rewardPerCycle : Nat; currentCycleCount : Nat; totalCycleCount : Nat }, Types.Error> {
    return #ok({
      totalReward = _totalReward;
      totalRewardClaimed = _totalRewardClaimed;
      totalRewardUnclaimed = _totalRewardUnclaimed;
      totalRewardBalance = _totalRewardBalance;
      totalRewardFee = _totalRewardFee;
      secondPerCycle = initArgs.secondPerCycle;
      rewardPerCycle = _rewardPerCycle;
      currentCycleCount = _currentCycleCount;
      totalCycleCount = _totalCycleCount;
    });
  };

  public shared (msg) func getRewardTokenBalance() : async Nat {
    return await _rewardTokenAdapter.balanceOf({
      owner = Principal.fromActor(this);
      subaccount = null;
    });
  };

  public shared (msg) func getPoolMeta() : async {
    poolMetadata : {
      sqrtPriceX96 : Nat;
      tick : Int;
      toICPPrice : Float;
      zeroForOne : Bool;
    };
    rewardPoolMetadata : {
      sqrtPriceX96 : Nat;
      tick : Int;
      toICPPrice : Float;
      zeroForOne : Bool;
    };
  } {
    return {
      poolMetadata = {
        sqrtPriceX96 = _poolMetadata.sqrtPriceX96;
        tick = _poolMetadata.tick;
        toICPPrice = _poolMetadata.toICPPrice;
        zeroForOne = _poolZeroForOne;
      };
      rewardPoolMetadata = {
        sqrtPriceX96 = _rewardPoolMetadata.sqrtPriceX96;
        tick = _rewardPoolMetadata.tick;
        toICPPrice = _rewardPoolMetadata.toICPPrice;
        zeroForOne = _rewardPoolZeroForOne;
      };
    };
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

  public shared (msg) func getCycleInfo() : async Result.Result<Types.CycleInfo, Types.Error> {
    return #ok({ balance = Cycles.balance(); available = Cycles.available() });
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

    var previousStatus = _status;
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
    await _farmControllerAct.updateFarmInfo(
      _status,
      {
        stakedTokenTVL = _TVL.stakedTokenTVL;
        rewardTokenTVL = _TVL.rewardTokenTVL;
      },
    );
  };

  private func _syncPoolMeta() : async () {
    try {
      let poolMetadata = switch (await _swapPoolAct.metadata()) {
        case (#ok(poolMetadata)) { poolMetadata };
        case (#err(code)) { return };
      };
      let rewardPoolMetadata = switch (await _rewardPoolAct.metadata()) {
        case (#ok(poolMetadata)) { poolMetadata };
        case (#err(code)) { return };
      };
      _rewardPoolMetadata := {
        sqrtPriceX96 = rewardPoolMetadata.sqrtPriceX96;
        tick = rewardPoolMetadata.tick;
        toICPPrice = _computeToICPPrice(
          if (_rewardPoolZeroForOne) { _rewardTokenDecimals } else {
            _ICPDecimals;
          },
          if (_rewardPoolZeroForOne) { _ICPDecimals } else {
            _rewardTokenDecimals;
          },
          rewardPoolMetadata.sqrtPriceX96,
          _rewardPoolZeroForOne,
        );
      };
      _poolMetadata := {
        sqrtPriceX96 = poolMetadata.sqrtPriceX96;
        tick = poolMetadata.tick;
        toICPPrice = _computeToICPPrice(_poolToken0Decimals, _poolToken1Decimals, poolMetadata.sqrtPriceX96, _poolZeroForOne);
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
          totalWeightedRatio := totalWeightedRatio + deposit.liquidity * (currentTime - deposit.initTime);
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
          rewardAmount := _computeReward(deposit.liquidity * (currentTime - deposit.initTime), totalWeightedRatio);
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
            token0Amount = amountResult.amount0;
            token1Amount = amountResult.amount1;
          },
        );
      };
      _currentCycleCount := _currentCycleCount + 1;
      _poolToken0Amount := IntUtils.toNat(poolToken0Amount, 512);
      _poolToken1Amount := IntUtils.toNat(poolToken1Amount, 512);
      // update TVL
      _updateTVL();
    } catch (e) {
      _errorLogBuffer.add("_distributeReward failed " # debug_show (Error.message(e)) # " . nowTime: " # debug_show (_getTime()));
    };
  };

  private func _updateTVL() {
    _TVL.stakedTokenTVL := if (_poolZeroForOne) {
      Float.add(
        Float.mul(
          Float.div(Float.fromInt(_poolToken0Amount), Float.fromInt(SafeInt.Int256(10 ** _poolToken0Decimals).val())),
          _poolMetadata.toICPPrice,
        ),
        Float.div(Float.fromInt(_poolToken1Amount), Float.fromInt(SafeInt.Int256(10 ** _poolToken1Decimals).val())),
      );
    } else {
      Float.add(
        Float.mul(
          Float.div(Float.fromInt(_poolToken1Amount), Float.fromInt(SafeInt.Int256(10 ** _poolToken1Decimals).val())),
          _poolMetadata.toICPPrice,
        ),
        Float.div(Float.fromInt(_poolToken0Amount), Float.fromInt(SafeInt.Int256(10 ** _poolToken0Decimals).val())),
      );
    };
    _TVL.rewardTokenTVL := if (Text.equal(initArgs.ICP.address, initArgs.rewardToken.address)) {
      Float.div(Float.fromInt(_totalReward), Float.fromInt(SafeInt.Int256(10 ** _rewardTokenDecimals).val()));
    } else {
      Float.mul(
        Float.div(Float.fromInt(_totalReward), Float.fromInt(SafeInt.Int256(10 ** _rewardTokenDecimals).val())),
        _rewardPoolMetadata.toICPPrice,
      );
    };
  };

  private func _computeReward(weightedRatio : Nat, totalWeightedRatio : Nat) : Nat {
    var excessDecimal = SafeUint.Uint512(100000000);
    var weightedRatioXe9 = SafeUint.Uint512(weightedRatio).mul(excessDecimal);
    // Debug.print("weightedRatioXe9: " # debug_show (weightedRatioXe9.val()));

    var rate = if (totalWeightedRatio == 0) { SafeUint.Uint512(0) } else {
      weightedRatioXe9.div(SafeUint.Uint512(totalWeightedRatio));
    };
    // Debug.print("rate: " # debug_show (rate.val()));

    var reward = SafeUint.Uint512(_rewardPerCycle).mul(rate).div(excessDecimal).val();
    // Debug.print("reward: " # debug_show (reward));

    _totalRewardUnclaimed := _totalRewardUnclaimed + reward;
    _totalRewardBalance := _totalRewardBalance - reward;
    return reward;
  };

  private func _getTokenAmounts(positionIds : [Nat]) : Result.Result<{ totalLiquidity : Nat; totalAmount0 : Int; totalAmount1 : Int }, Types.Error> {
    if (positionIds.size() == 0) {
      return #ok({ totalLiquidity = 0; totalAmount0 = 0; totalAmount1 = 0 });
    };
    var totalAmount0 : Int = 0;
    var totalAmount1 : Int = 0;
    var totalLiquidity : Nat = 0;
    for (positionId in positionIds.vals()) {
      switch (_depositMap.get(positionId)) {
        case (?deposit) {
          let amountResult = switch (_getTokenAmountByLiquidity(deposit.tickLower, deposit.tickUpper, deposit.liquidity)) {
            case (#ok(result)) { result };
            case (#err(msg)) { return #err(#InternalError(msg)) };
          };
          totalAmount0 := totalAmount0 + amountResult.amount0;
          totalAmount1 := totalAmount1 + amountResult.amount1;
          totalLiquidity := totalLiquidity + deposit.liquidity;
        };
        case (_) {};
      };
    };
    return #ok({
      totalLiquidity = totalLiquidity;
      totalAmount0 = totalAmount0;
      totalAmount1 = totalAmount1;
    });
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

  private func _computeToICPPrice(decimals0 : Nat, decimals1 : Nat, sqrtPriceX96 : Nat, notReverse : Bool) : Float {
    let DECIMALS = 10000000;
    let Q192 = (2 ** 96) ** 2;

    let part1 = sqrtPriceX96 ** 2 * 10 ** decimals0 * DECIMALS;
    let part2 = Q192 * 10 ** decimals1;
    let priceWithDecimals = Float.div(Float.fromInt(part1), Float.fromInt(part2));
    let price = Float.div(priceWithDecimals, Float.fromInt(DECIMALS));

    return if (notReverse) { price } else { Float.div(1, price) };
  };

  private func _getTime() : Nat {
    return IntUtils.toNat(Time.now() / 1000000000, 256);
  };

  // --------------------------- ACL ------------------------------------
  private stable var _admins : [Principal] = [initArgs.creator];
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
    return Prim.isController(caller);
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

  // --------------------------- SCHEDULE ------------------------------------
  let _distributeRewardPerCycle = Timer.recurringTimer(
    #seconds(initArgs.secondPerCycle),
    _distributeReward,
  );
  let _syncPoolMetaPer60s = Timer.recurringTimer(
    #seconds(60),
    _syncPoolMeta,
  );
  let _updateStatusPer60s = Timer.recurringTimer(
    #seconds(60),
    _updateStatus,
  );
  // --------------------------- Version Control ------------------------------------
  private var _version : Text = "3.0.0";
  public query func getVersion() : async Text { _version };

  // --------------------------- LIFE CYCLE -----------------------------------
  system func preupgrade() {
    _userPositionEntries := Iter.toArray(_userPositionMap.entries());
    _depositEntries := Iter.toArray(_depositMap.entries());
    _errorLogList := Buffer.toArray(_errorLogBuffer);
    _stakeRecordList := Buffer.toArray(_stakeRecordBuffer);
    _distributeRecordList := Buffer.toArray(_distributeRecordBuffer);
  };

  system func postupgrade() {
    for (record in _errorLogList.vals()) { _errorLogBuffer.add(record) };
    for (record in _stakeRecordList.vals()) { _stakeRecordBuffer.add(record) };
    for (record in _distributeRecordList.vals()) {
      _distributeRecordBuffer.add(record);
    };
    _stakeRecordList := [];
    _distributeRecordList := [];
    _errorLogList := [];
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
      case (#init args) { _hasPermission(caller) };
      case (#setAdmins args) { _hasPermission(caller) };
      // Admin
      case (#finishManually args) { _hasAdminPermission(caller) };
      case (#restartManually args) { _hasAdminPermission(caller) };
      case (#close args) { _hasAdminPermission(caller) };
      case (#clearErrorLog args) { _hasAdminPermission(caller) };
      case (#setLimitInfo args) { _hasAdminPermission(caller) };
      case (#withdrawRewardFee args) { Principal.equal(caller, initArgs.feeReceiverCid) };
      // Anyone
      case (_) { true };
    };
  };

};
