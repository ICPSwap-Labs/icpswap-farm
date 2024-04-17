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

    public let NOT_STARTED = "NOT_STARTED";
    public let LIVE = "LIVE";
    public let FINISHED = "FINISHED";
    public let CLOSED = "CLOSED";

    public func equal(x : Nat, y : Nat) : Bool {
        return Nat.equal(x, y);
    };
    public func hash(x : Nat) : Hash.Hash {
        return Prim.natToNat32(x);
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
        ICP : Token;
        rewardToken : Token;
        pool : Principal;
        rewardPool : Principal;
        startTime : Nat;
        endTime : Nat;
        refunder : Principal;
        totalReward : Nat;
        status : Text;
        secondPerCycle : Nat;
        token0AmountLimit : Nat;
        token1AmountLimit : Nat;
        priceInsideLimit : Bool;
        creator : Principal;
        farmControllerCid : Principal;
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
        totalRewardClaimed : Nat;
        totalRewardUnclaimed : Nat;
        numberOfStakes : Nat;
        userNumberOfStakes : Nat;
        status : Text;
        creator : Principal;
        positionIds: [Nat];
    };
    public type TransType = {
        #stake;
        #unstake;
        #claim;
        #distribute;
    };
    public type TVL = {
        stakedTokenTVL : Float;
        rewardTokenTVL : Float;
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
        #create : () -> (CreateFarmArgs);
        #updateFarmInfo : () -> (Text, Text, TVL);
        #getCycleInfo : () -> ();
        #getFarms : () -> Text;
        #getInitArgs : () -> ();
        #getGlobalTVL : () -> ();
        #setAdmins : () -> [Principal];
        #getAdmins : () -> ();
        #getVersion : () -> ();
    };
    public type FarmMsg = {
        #init : () -> InitFarmArgs;
        #stake : () -> (Nat);
        #unstake : () -> (Nat);
        #finishManually : () -> ();
        #close : () -> ();
        #clearErrorLog : () -> ();
        #setAdmins : () -> ([Principal]);
        #setLimitInfo : () -> (Nat, Nat, Nat, Bool);
        #getRewardInfo : () -> ([Nat]);
        #getFarmInfo : () -> (Text);
        #getUserPositions : () -> (Principal, Nat, Nat);
        #getUserTVL : () -> (Principal);
        #getVersion : () -> ();
        #getPositionIds : () -> ();
        #getLiquidityInfo : () -> ();
        #getDeposit : () -> (Nat);
        #getTVL : () -> ();
        #getConfigCids : () -> ();
        #getLimitInfo : () -> ();
        #getRewardMeta : () -> ();
        #getTokenBalance : () -> ();
        #getPoolMeta : () -> ();
        #getStakeRecord : () -> (Nat, Nat, Text);
        #getDistributeRecord : () -> (Nat, Nat, Text);
        #getCycleInfo : () -> ();
        #getAdmins : () -> ();
        #getErrorLog : () -> ();
    };

    public type IFarm = actor {
        init : shared () -> async ();
        stake : shared Nat -> async Result.Result<Text, Error>;
        unstake : shared Nat -> async Result.Result<Text, Error>;
        getRewardInfo : query [Nat] -> async Result.Result<Nat, Error>;
        getFarmInfo : query Text -> async Result.Result<FarmInfo, Error>;
        getDeposit : query Nat -> async Result.Result<Deposit, Error>;
        getTVL : query () -> async Result.Result<{ stakedTokenTVL : Float; rewardTokenTVL : Float }, Error>;
    };
};
