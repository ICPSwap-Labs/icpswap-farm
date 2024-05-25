import Bool "mo:base/Bool";
import Time "mo:base/Time";
import Int "mo:base/Int";
import Buffer "mo:base/Buffer";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Principal "mo:base/Principal";
import Result "mo:base/Result";
import Text "mo:base/Text";
import Hash "mo:base/Hash";
import Prim "mo:⛔";

module {

    public func equal(x : Nat, y : Nat) : Bool {
        return Nat.equal(x, y);
    };
    public func hash(x : Nat) : Hash.Hash {
        return Prim.natToNat32(x);
    };

    public type FarmStatus = {
        #NOT_STARTED;
        #LIVE;
        #FINISHED;
        #CLOSED;
    };
    public type Page<T> = {
        totalElements : Nat;
        content : [T];
        offset : Nat;
        limit : Nat;
    };
    public type CycleInfo = {
        balance : Nat;
        available : Nat;
    };
    public type Token = {
        address : Text;
        standard : Text;
    };
    public type SwapArgs = {
        operator : Principal;
        zeroForOne : Bool;
        amountIn : Text;
        amountOutMinimum : Text;
    };
    public type CreateFarmArgs = {
        rewardToken : Token;
        rewardAmount : Nat;
        rewardPool : Principal;
        pool : Principal;
        startTime : Nat;
        endTime : Nat;
        secondPerCycle : Nat;
        token0AmountLimit : Nat;
        token1AmountLimit : Nat;
        priceInsideLimit : Bool;
        refunder : Principal;
    };
    public type InitFarmArgs = {
        rewardToken : Token;
        pool : Principal;
        rewardPool : Principal;
        startTime : Nat;
        endTime : Nat;
        refunder : Principal;
        totalReward : Nat;
        status : FarmStatus;
        secondPerCycle : Nat;
        token0AmountLimit : Nat;
        token1AmountLimit : Nat;
        priceInsideLimit : Bool;
        creator : Principal;
        farmControllerCid : Principal;
        feeReceiverCid : Principal;
        fee : Nat;
        governanceCid : ?Principal;
    };
    public type PoolMetadata = {
        key : Text;
        token0 : Token;
        token1 : Token;
        fee : Nat;
        tick : Int;
        liquidity : Nat;
        sqrtPriceX96 : Nat;
        maxLiquidityPerTick : Nat;
    };
    public type UserPositionInfo = {
        tickLower : Int;
        tickUpper : Int;
        liquidity : Nat;
        feeGrowthInside0LastX128 : Nat;
        feeGrowthInside1LastX128 : Nat;
        tokensOwed0 : Nat;
        tokensOwed1 : Nat;
    };
    public type Error = {
        #CommonError;
        #InternalError : Text;
        #UnsupportedToken : Text;
        #InsufficientFunds;
    };
    public type Deposit = {
        owner : Principal;
        holder : Principal;
        initTime : Nat;
        positionId : Nat;
        tickLower : Int;
        tickUpper : Int;
        liquidity : Nat;
        rewardAmount : Nat;
        token0Amount : Int;
        token1Amount : Int;
    };
    public type FarmInfo = {
        rewardToken : Token;
        pool : Principal;
        poolToken0 : Token;
        poolToken1 : Token;
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
        status : FarmStatus;
        creator : Principal;
        positionIds : [Nat];
    };
    public type TransType = {
        #stake;
        #unstake;
        #harvest;
        #distribute;
        #withdraw;
    };
    public type TokenAmount = {
        address : Text;
        standard : Text;
        amount : Nat;
    };
    public type TVL = {
        poolToken0 : TokenAmount;
        poolToken1 : TokenAmount;
        rewardToken : TokenAmount;
    };
    public type SwapPositionInfo = {
        pool : Text;
        token0 : Token;
        token1 : Token;
        fee : Nat;
        tickLower : Int;
        tickUpper : Int;
        liquidity : Nat;
        positionId : Text;
        tokensOwed0 : Nat;
        tokensOwed1 : Nat;
    };
    public type StakeRecord = {
        timestamp : Nat;
        transType : TransType;
        positionId : Nat;
        from : Principal;
        to : Principal;
        amount : Nat;
        liquidity : Nat;
    };
    public type DistributeRecord = {
        timestamp : Nat;
        positionId : Nat;
        owner : Principal;
        rewardGained : Nat;
        rewardTotal : Nat;
    };
    public type LockState = {
        locked : Bool;
        time : Time.Time;
    };
    public type FarmControllerMsg = {
        #addFarmControllers : () -> (Principal, [Principal]);
        #create : () -> CreateFarmArgs;
        #getAdmins : () -> ();
        #getAllFarmId : () -> ();
        #getAllFarms : () -> ();
        #getCycleInfo : () -> ();
        #getFarms : () -> ?FarmStatus;
        #getFee : () -> ();
        #getInitArgs : () -> ();
        #getVersion : () -> ();
        #removeFarmControllers : () -> (Principal, [Principal]);
        #setAdmins : () -> [Principal];
        #setFarmAdmins : () -> (Principal, [Principal]);
        #setFee : () -> Nat;
        #updateFarmInfo : () -> (FarmStatus, TVL)
    };
    public type FarmMsg = {
        #clearErrorLog : () -> ();
        #close : () -> ();
        #finishManually : () -> ();
        #getAdmins : () -> ();
        #getCycleInfo : () -> ();
        #getDeposit : () -> Nat;
        #getDistributeRecord : () -> (Nat, Nat, Text);
        #getErrorLog : () -> ();
        #getFarmInfo : () -> Text;
        #getInitArgs : () -> ();
        #getLimitInfo : () -> ();
        #getLiquidityInfo : () -> ();
        #getPoolMeta : () -> ();
        #getPositionIds : () -> ();
        #getRewardInfo : () -> [Nat];
        #getRewardMeta : () -> ();
        #getRewardTokenBalance : () -> ();
        #getStakeRecord : () -> (Nat, Nat, Text);
        #getTVL : () -> ();
        #getUserDeposits : () -> Principal;
        #getUserTVL : () -> Principal;
        #getVersion : () -> ();
        #init : () -> ();
        #restartManually : () -> ();
        #setAdmins : () -> [Principal];
        #setLimitInfo : () -> (Nat, Nat, Nat, Bool);
        #stake : () -> Nat;
        #unstake : () -> Nat;
        #withdrawRewardFee : () -> ();
    };
    public type FarmFeeReceiver = {
        #claim : () -> (Principal);
        #getCycleInfo : () -> ();
        #getVersion : () -> ();
        #transfer : () -> (Token, Principal, Nat);
        #transferAll : () -> (Token, Principal);
    };

    public type IFarmController = actor {
        create : shared CreateFarmArgs -> async Result.Result<Text, Text>;
        setAdmins : shared [Principal] -> async ();
        getAdmins : query () -> async Result.Result<[Principal], Error>;
        getCycleInfo : shared () -> async Result.Result<CycleInfo, Error>;
        getAllFarmId : query () -> async Result.Result<[Principal], Error>;
    };

    public type IFarm = actor {
        init : shared () -> async ();
        setAdmins : shared [Principal] -> async ();
        stake : shared Nat -> async Result.Result<Text, Error>;
        unstake : shared Nat -> async Result.Result<Text, Error>;
        getRewardInfo : query [Nat] -> async Result.Result<Nat, Error>;
        getFarmInfo : query Text -> async Result.Result<FarmInfo, Error>;
        getDeposit : query Nat -> async Result.Result<Deposit, Error>;
        getTVL : query () -> async Result.Result<{ stakedTokenTVL : Float; rewardTokenTVL : Float }, Error>;
        withdrawRewardFee : query () -> async Result.Result<Text, Error>;
    };
};
