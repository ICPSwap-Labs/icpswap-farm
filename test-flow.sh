#!/bin/bash
# set -e
# clear
dfx stop
rm -rf .dfx
mv dfx.json dfx.json.bak
cat > dfx.json <<- EOF
{
  "canisters": {
    "FarmController": {
      "main": "./src/FarmController.mo",
      "type": "motoko"
    },
    "FarmFeeReceiver": {
      "main": "./src/FarmFeeReceiver.mo",
      "type": "motoko"
    },
    "SwapFeeReceiver": {
      "main": ".vessel/icpswap-v3-service/v3.4.2/src/SwapFeeReceiver.mo",
      "type": "motoko"
    },
    "SwapFactory": {
      "main": ".vessel/icpswap-v3-service/v3.4.2/src/SwapFactory.mo",
      "type": "motoko"
    },
    "PasscodeManager": {
      "main": ".vessel/icpswap-v3-service/v3.4.2/src/PasscodeManager.mo",
      "type": "motoko"
    },
    "PositionIndex": {
      "main": ".vessel/icpswap-v3-service/v3.4.2/src/PositionIndex.mo",
      "type": "motoko"
    },
    "TrustedCanisterManager": {
      "main": ".vessel/icpswap-v3-service/v3.4.2/src/TrustedCanisterManager.mo",
      "type": "motoko"
    },
    "Test": {
      "main": ".vessel/icpswap-v3-service/v3.4.2/test/Test.mo",
      "type": "motoko"
    },
    "DIP20A": {
      "wasm": ".vessel/icpswap-v3-service/v3.4.2/test/dip20/lib.wasm",
      "type": "custom",
      "candid": ".vessel/icpswap-v3-service/v3.4.2/test/dip20/lib.did"
    },
    "DIP20B": {
      "wasm": ".vessel/icpswap-v3-service/v3.4.2/test/dip20/lib.wasm",
      "type": "custom",
      "candid": ".vessel/icpswap-v3-service/v3.4.2/test/dip20/lib.did"
    },
    "ICRC2": {
      "wasm": ".vessel/icpswap-v3-service/v3.4.2/test/icrc2/icrc2.wasm",
      "type": "custom",
      "candid": ".vessel/icpswap-v3-service/v3.4.2/test/icrc2/icrc2.did"
    },
    "base_index": {
      "wasm": ".vessel/icpswap-v3-service/v3.4.2/test/base_index/base_index.wasm",
      "type": "custom",
      "candid": ".vessel/icpswap-v3-service/v3.4.2/test/base_index/base_index.did"
    },
    "node_index": {
      "wasm": ".vessel/icpswap-v3-service/v3.4.2/test/node_index/node_index.wasm",
      "type": "custom",
      "candid": ".vessel/icpswap-v3-service/v3.4.2/test/node_index/node_index.did"
    },
    "price": {
      "wasm": ".vessel/icpswap-v3-service/v3.4.2/test/price/price.wasm",
      "type": "custom",
      "candid": ".vessel/icpswap-v3-service/v3.4.2/test/price/price.did"
    }
  },
  "defaults": { "build": { "packtool": "vessel sources" } }, "networks": { "local": { "bind": "127.0.0.1:8000", "type": "ephemeral" } }, "version": 1
}
EOF
TOTAL_SUPPLY="1000000000000000000"
# TRANS_FEE="100000000";
TRANS_FEE="0";
MINTER_PRINCIPAL="$(dfx identity get-principal)"

dfx start --clean --background
echo "-=========== create all"
dfx canister create --all
echo "-=========== build all"
dfx build
echo
echo "==> Install canisters"
echo
echo "==> install ICRC2"
dfx canister install ICRC2 --argument="( record {name = \"ICRC2\"; symbol = \"ICRC2\"; decimals = 8; fee = 0; max_supply = 1_000_000_000_000; initial_balances = vec {record {record {owner = principal \"$MINTER_PRINCIPAL\";subaccount = null;};100_000_000}};min_burn_amount = 10_000;minting_account = null;advanced_settings = null; })"
echo "==>install DIP20"
dfx canister install DIP20A --argument="(\"DIPA Logo\", \"DIPA\", \"DIPA\", 8, $TOTAL_SUPPLY, principal \"$MINTER_PRINCIPAL\", $TRANS_FEE)"
dfx canister install DIP20B --argument="(\"DIPB Logo\", \"DIPB\", \"DIPB\", 8, $TOTAL_SUPPLY, principal \"$MINTER_PRINCIPAL\", $TRANS_FEE)"

echo "==> install SwapFeeReceiver"
dfx canister install SwapFeeReceiver
echo "==> install TrustedCanisterManager"
dfx canister install TrustedCanisterManager --argument="(null)"
echo "==> install Test"
dfx canister install Test
echo "==> install price"
dfx deploy price
echo "==> install base_index"
dfx deploy base_index --argument="(principal \"$(dfx canister id price)\", principal \"$(dfx canister id node_index)\")"
echo "==> install node_index"
dfx deploy node_index --argument="(\"$(dfx canister id base_index)\", \"$(dfx canister id price)\")"
echo "==> install SwapFactory"
dfx deploy SwapFactory --argument="(principal \"$(dfx canister id base_index)\", principal \"$(dfx canister id SwapFeeReceiver)\", principal \"$(dfx canister id PasscodeManager)\", principal \"$(dfx canister id TrustedCanisterManager)\", null)"

dfx canister deposit-cycles 50698725619460 SwapFactory

echo "==> install PositionIndex"
dfx canister install PositionIndex --argument="(principal \"$(dfx canister id SwapFactory)\")"
echo "==> install PasscodeManager"
dfx canister install PasscodeManager --argument="(principal \"$(dfx canister id ICRC2)\", 100000000, principal \"$(dfx canister id SwapFactory)\")"
echo "==> install FarmFeeReceiver"
dfx canister install FarmFeeReceiver
echo "==> install FarmController"
dfx canister install FarmController --argument="(record {address = \"$(dfx canister id ICRC2)\"; standard = \"ICRC2\";}, principal \"$(dfx canister id FarmFeeReceiver)\", null)"

dipAId=`dfx canister id DIP20A`
dipBId=`dfx canister id DIP20B`
testId=`dfx canister id Test`
infoId=`dfx canister id base_index`
swapFactoryId=`dfx canister id SwapFactory`
positionIndexId=`dfx canister id PositionIndex`
swapFeeReceiverId=`dfx canister id SwapFeeReceiver`
farmControllerId=`dfx canister id FarmController`
farmFeeReceiverId=`dfx canister id FarmFeeReceiver`
zeroForOne="true"
ICP="$(dfx canister id ICRC2)"
echo "==> infoId (\"$infoId\")"
echo "==> positionIndexId (\"$positionIndexId\")"
echo "==> swapFeeReceiverId (\"$swapFeeReceiverId\")"
echo "==> farmControllerId (\"$farmControllerId\")"
echo "==> ICP (\"$ICP\")"

dfx canister call base_index addClient "(principal \"$swapFactoryId\")"


if [[ "$dipAId" < "$dipBId" ]]; then
    token0="$dipAId"
    token1="$dipBId"
else
    token0="$dipBId"
    token1="$dipAId"
fi
echo "======================================="
echo "=== token0: $token0"
echo "=== token1: $token1"
echo "======================================="

# subaccount=`dfx canister call Test getSubaccount |grep text__ |awk -F"text__" '{print substr($2,4,128)}'`
echo 

function balanceOf()
{
    if [ $3 = "null" ]; then
        subaccount="null"
    else
        subaccount="opt principal \"$3\""
    fi
    balance=`dfx canister call Test testTokenAdapterBalanceOf "(\"$1\", \"DIP20\", principal \"$2\", $subaccount)"`
    echo $balance
}

# create pool 1
function create_pool_1() #sqrtPriceX96
{
    dfx canister call ICRC2 icrc2_approve "(record{amount=1000000000000;created_at_time=null;expected_allowance=null;expires_at=null;fee=null;from_subaccount=null;memo=null;spender=record {owner= principal \"$(dfx canister id PasscodeManager)\";subaccount=null;}})"
    dfx canister call PasscodeManager depositFrom "(record {amount=100000000;fee=0;})"
    dfx canister call PasscodeManager requestPasscode "(principal \"$token0\", principal \"$token1\", 3000)"
    
    result=`dfx canister call SwapFactory createPool "(record {token0 = record {address = \"$token0\"; standard = \"DIP20\";}; token1 = record {address = \"$token1\"; standard = \"DIP20\";}; fee = 3000; sqrtPriceX96 = \"$1\"})"`
    if [[ ! "$result" =~ " ok = record " ]]; then
        echo "\033[31mcreate pool fail. $result - \033[0m"
    fi
    echo "create_pool result: $result"
    poolId_1=`echo $result | awk -F"canisterId = principal \"" '{print $2}' | awk -F"\";" '{print $1}'`
    dfx canister call $dipAId approve "(principal \"$poolId_1\", $TOTAL_SUPPLY)"
    dfx canister call $dipBId approve "(principal \"$poolId_1\", $TOTAL_SUPPLY)"
    dfx canister call PositionIndex updatePoolIds 
}

# create pool
function create_pool_2() #sqrtPriceX96
{
    dfx canister call ICRC2 icrc2_approve "(record{amount=1000000000000;created_at_time=null;expected_allowance=null;expires_at=null;fee=null;from_subaccount=null;memo=null;spender=record {owner= principal \"$(dfx canister id PasscodeManager)\";subaccount=null;}})"
    dfx canister call PasscodeManager depositFrom "(record {amount=100000000;fee=0;})"
    dfx canister call PasscodeManager requestPasscode "(principal \"$token1\", principal \"$ICP\", 3000)"
    
    result=`dfx canister call SwapFactory createPool "(record {token0 = record {address = \"$token1\"; standard = \"DIP20\";}; token1 = record {address = \"$ICP\"; standard = \"ICRC2\";}; fee = 3000; sqrtPriceX96 = \"$1\"})"`
    if [[ ! "$result" =~ " ok = record " ]]; then
        echo "\033[31mcreate pool fail. $result - \033[0m"
    fi
    echo "create_pool result: $result"
    poolId_2=`echo $result | awk -F"canisterId = principal \"" '{print $2}' | awk -F"\";" '{print $1}'`
    dfx canister call PositionIndex updatePoolIds 
}

function depost() # token tokenAmount
{   
    result=`dfx canister call $poolId_1 depositFrom "(record {token = \"$1\"; amount = $2: nat; fee = $TRANS_FEE: nat; })"`
    result=${result//"_"/""}
    if [[ "$result" =~ "$2" ]]; then
      echo "\033[32m deposit $1 success. \033[0m"
    else
      echo "\033[31m deposit $1 fail. $result, $2 \033[0m"
    fi
}

function mint(){ #tickLower tickUpper amount0Desired amount0Min amount1Desired amount1Min ### liquidity tickCurrent sqrtRatioX96
    result=`dfx canister call $poolId_1 mint "(record { token0 = \"$token0\"; token1 = \"$token1\"; fee = 3000: nat; tickLower = $1: int; tickUpper = $2: int; amount0Desired = \"$3\"; amount1Desired = \"$5\"; })"`
    echo "mint result: $result"
    info=`dfx canister call $poolId_1 metadata`
    info=${info//"_"/""}
    if [[ "$info" =~ "$7" ]] && [[ "$info" =~ "$8" ]] && [[ "$info" =~ "$9" ]]; then
      echo "\033[32m mint success. \033[0m"
    else
      echo "\033[31m mint fail. $info \n expected $7 $8 $9 \033[0m"
    fi
    dfx canister call PositionIndex addPoolId "(\"$poolId_1\")"
}

function swap() #depostToken depostAmount amountIn amountOutMinimum ### liquidity tickCurrent sqrtRatioX96  token0BalanceAmount token1BalanceAmount zeroForOne
{
    depost $1 $2    
    if [[ "$1" =~ "$token0" ]]; then
        result=`dfx canister call $poolId_1 swap "(record { zeroForOne = true; amountIn = \"$3\"; amountOutMinimum = \"$4\"; })"`
    else
        result=`dfx canister call $poolId_1 swap "(record { zeroForOne = false; amountIn = \"$3\"; amountOutMinimum = \"$4\"; })"`
    fi
    echo "swap result: $result"

    result=`dfx canister call $poolId_1 getUserUnusedBalance "(principal \"$MINTER_PRINCIPAL\")"`

    withdrawAmount0=${result#*=}
    withdrawAmount0=${withdrawAmount0#*=}
    withdrawAmount0=${withdrawAmount0%:*}
    withdrawAmount0=${withdrawAmount0//" "/""}

    withdrawAmount1=${result##*=}
    withdrawAmount1=${withdrawAmount1%:*}
    withdrawAmount1=${withdrawAmount1//" "/""}

    result=`dfx canister call $poolId_1 withdraw "(record {token = \"$token0\"; fee = $TRANS_FEE: nat; amount = $withdrawAmount0: nat;})"`
    result=`dfx canister call $poolId_1 withdraw "(record {token = \"$token1\"; fee = $TRANS_FEE: nat; amount = $withdrawAmount1: nat;})"`
    
    echo "\033[32m swap success. \033[0m"
}

function checkBalance(){
    token0BalanceResult="$(balanceOf $token0 $MINTER_PRINCIPAL null)"
    echo "token0 $MINTER_PRINCIPAL balance: $token0BalanceResult"
    token1BalanceResult="$(balanceOf $token1 $MINTER_PRINCIPAL null)"
    echo "token1 $MINTER_PRINCIPAL balance: $token1BalanceResult"
    token0BalanceResult=${token0BalanceResult//"_"/""}
    token1BalanceResult=${token1BalanceResult//"_"/""}
    if [[ "$token0BalanceResult" =~ "$1" ]] && [[ "$token1BalanceResult" =~ "$2" ]]; then
      echo "\033[32m token balance success. \033[0m"
    else
      echo "\033[31m token balance fail. $info \n expected $1 $2\033[0m"
    fi
}

function create_farm()
{
    current_timestamp=$(date +%s)

    one_minutes_seconds=$((60 * 1))
    one_minutes_later_timestamp=$((current_timestamp + one_minutes_seconds))

    ten_minutes_seconds=$((60 * 10))
    ten_minutes_later_timestamp=$((current_timestamp + ten_minutes_seconds))

    one_day_seconds=$((60 * 60 * 24))
    one_day_later_timestamp=$((current_timestamp + one_day_seconds))

    result=`dfx canister call FarmController create "(record {rewardToken=record {address = \"$token1\"; standard = \"DIP20\";}; rewardAmount = 10000000000; rewardPool = principal \"$poolId_2\"; pool = principal \"$poolId_1\"; startTime = $one_minutes_later_timestamp; endTime = $ten_minutes_later_timestamp; secondPerCycle = 30; token0AmountLimit = 0; token1AmountLimit = 0; priceInsideLimit = false; refunder = principal \"$MINTER_PRINCIPAL\";})"`
    # result=`dfx canister call FarmController create "(record {rewardToken=record {address = \"$token1\"; standard = \"DIP20\";}; rewardAmount = 10000000000; rewardPool = principal \"$poolId_2\"; pool = principal \"$poolId_1\"; startTime = $one_minutes_later_timestamp; endTime = $ten_minutes_later_timestamp; secondPerCycle = 30; token0AmountLimit = 100000000000000; token1AmountLimit = 100000000000000; priceInsideLimit = true; refunder = principal \"$MINTER_PRINCIPAL\";})"`
    echo "\033[32m create farm result: $result \033[0m"

    if [[ $result =~ ok\ =\ \"([^\"]+)\" ]]; then
        farmId="${BASH_REMATCH[1]}"
    fi
    echo "farmId: $farmId"

    result=`dfx canister call $token1 transfer "(principal \"$farmId\", 10000000000)"`
    echo "transfer to farm result: $result"
}

function close_farm()
{
    result=`dfx canister call $farmId close`
    echo "\033[32m close result: $result \033[0m"
}

function withdraw_reward_fee()
{
    result=`dfx canister call $farmId getRewardMeta`
    echo "RewardMeta: $result"   

    result=`dfx canister call $farmFeeReceiverId harvest "(principal \"$farmId\")"`
    echo "\033[32m withdraw_reward_fee result: $result \033[0m"

    result=`dfx canister call $farmId getRewardMeta`
    echo "RewardMeta: $result" 
}

function stake() # positionId
{
    result=`dfx canister call $poolId_1 approvePosition "(principal \"$farmId\", $1:nat)"`
    echo "approvePosition result: $result"

    result=`dfx canister call $farmId stake "($1:nat)"`
    echo "\033[32m stake result: $result \033[0m"
}

function unstake() # positionId
{
    result=`dfx canister call $farmId getRewardMeta`
    echo "RewardMeta: $result"    

    rewardTokenBalance="$(balanceOf $token1 $MINTER_PRINCIPAL null)"
    echo "$MINTER_PRINCIPAL reward token balance: $rewardTokenBalance"

    result=`dfx canister call $farmId unstake "($1:nat)"`
    echo "\033[32m unstake result: $result \033[0m"

    result=`dfx canister call $farmId getRewardMeta`
    echo "RewardMeta: $result"  

    # rewardTokenBalance="$(balanceOf $token1 $MINTER_PRINCIPAL null)"
    # echo "$MINTER_PRINCIPAL reward token balance: $rewardTokenBalance"
}

function check_distribution() # positionId
{
    # result=`dfx canister call $farmId getStakeRecord "(0:nat, 100:nat, \"\")"`
    # echo "stake record: $result"
    
    # result=`dfx canister call $farmId getDistributeRecord "(0:nat, 100:nat, \"\")"`
    # echo "distribute record: $result"

    # result=`dfx canister call $farmId getDeposit "($1:nat)"`
    # echo "deposit info: $result"

    result=`dfx canister call $farmId getTVL`
    echo "TVL: $result"
}

function test()
{   
    echo
    echo test begin
    echo
    echo "==> create position pool"
    create_pool_1 274450166607934908532224538203
    echo "==> create reward pool"
    create_pool_2 274450166607934908532224538203
    echo "==> create farm"
    create_farm

    echo
    echo "==> 1 mint"
    depost $token0 100000000000
    depost $token1 1667302813453
    #tickLower tickUpper amount0Desired amount0Min amount1Desired amount1Min ### liquidity tickCurrent sqrtRatioX96
    mint -23040 46080 100000000000 92884678893 1667302813453 1573153132015 529634421680 24850 274450166607934908532224538203
    # mint 52980 92100 100000000000 92884678893 1667302813453 1573153132015 529634421680 24850 274450166607934908532224538203

    echo "==> 2 stake"
    stake 1

    sleep 120

    echo "==> 3 stake"
    stake 1

    echo "==> 4 swap"
    #depostToken depostAmount amountIn amountOutMinimum ### liquidity tickCurrent sqrtRatioX96 token0BalanceAmount token1BalanceAmount
    swap $token0 100000000000 100000000000 658322113914 529634421680 14808 166123716848874888729218662825 999999800000000000 999999056851511853

    echo "==> 5 swap"
    #depostToken depostAmount amountIn amountOutMinimum ### liquidity tickCurrent sqrtRatioX96 token0BalanceAmount token1BalanceAmount
    swap $token1 200300000000 200300000000 34999517311 529634421680 18116 195996761539654227777570705349 999999838499469043 999998856551511853

    # sleep 120

    echo "==> 6 mint"
    depost $token0 2340200000000
    depost $token1 12026457043801
    #tickLower tickUpper amount0Desired amount0Min amount1Desired amount1Min ### liquidity tickCurrent sqrtRatioX96
    mint -16080 92220 2340200000000 2228546458622 12026457043801 11272984126445 6464892363717 18116 195996761539654227777570705349

    echo "==> 7 stake"
    stake 2

    echo "==> 8 swap"
    #depostToken depostAmount amountIn amountOutMinimum ### liquidity tickCurrent sqrtRatioX96 token0BalanceAmount token1BalanceAmount
    swap $token1 900934100000000 900934100000000 2274000482681 0 887271 1461446703485210103287273052203988822378723970341 999999999699999993 999398897657090959

    echo "==> 9 swap"
    #depostToken depostAmount amountIn amountOutMinimum ### liquidity tickCurrent sqrtRatioX96 token0BalanceAmount token1BalanceAmount
    swap $token0 10000000000 10000000000 78411589305243 5935257942037 89098 6815937996742481301561907102830 999999989699999993 999485150405326727

    # sleep 120

    unstake 1

    # echo "==> 10 mint"
    # depost $token0 109232300000000
    # depost $token1 988000352041693230
    # #tickLower tickUpper amount0Desired amount0Min amount1Desired amount1Min ### liquidity tickCurrent sqrtRatioX96
    # mint 45000 115140 109232300000000 102249810937012 988000352041693230 931015571568576453 12913790762040195 89098 6815937996742481301561907102830

    # echo "==> 11 swap"
    # #depostToken depostAmount amountIn amountOutMinimum ### liquidity tickCurrent sqrtRatioX96 token0BalanceAmount token1BalanceAmount
    # swap $token0 20000000000 20000000000 134142648626931 12913790762040195 89095 6815032711583577861813878240260 999890737399999993 11632355277123122

    # echo "==> 12 swap"
    # #depostToken depostAmount amountIn amountOutMinimum ### liquidity tickCurrent sqrtRatioX96 token0BalanceAmount token1BalanceAmount
    # swap $token0 200203100000000 200203100000000 576342038450924726 12913790762040195 72181 2925487520681317622364346051650 999690534299999993 645608597573140321

    unstake 2

    # echo "==> 13 decrease"
    # #positionId liquidity amount0Min amount1Min ###  liquidity tickCurrent sqrtRatioX96
    # decrease 3 12907855504098158 292494852582912 329709405464581002 5935257942037 72181 2925487520681317622364346051650

    # echo "==> 14 decrease"
    # #positionId liquidity amount0Min amount1Min ###  liquidity tickCurrent sqrtRatioX96
    # decrease 2 5935257942037 94237330101 205255638225991 0 72181 2925487520681317622364346051650

    # echo "==> 15 swap"
    # #depostToken depostAmount amountIn amountOutMinimum ### liquidity tickCurrent sqrtRatioX96 token0BalanceAmount token1BalanceAmount
    # swap $token0 200000000000 200000000000 381035193378 529634421680 14832 166321252212714690643584399335 999999799699999990 999999042915031684

    # echo "==> 16 mint"
    # depost $token0 1000200000000
    # depost $token1 0
    # #tickLower tickUpper amount0Desired amount0Min amount1Desired amount1Min ### liquidity tickCurrent sqrtRatioX96
    # mint 52980 92100 1000200000000 1000200000000 0 0 529634421680 14832 166321252212714690643584399335

    # stake 4

    # echo "==> 17 swap"
    # #depostToken depostAmount amountIn amountOutMinimum ### liquidity tickCurrent sqrtRatioX96 token0BalanceAmount token1BalanceAmount
    # swap $token1 4924352000000 4924352000000 184529093407 16470362268400 53041 1123584027070855708721216766866 999999002482002738 999994118563031684

    # echo "==> 18 mint"
    # depost $token0 2049400000000
    # depost $token1 0
    # #tickLower tickUpper amount0Desired amount0Min amount1Desired amount1Min ### liquidity tickCurrent sqrtRatioX96
    # mint 99060 104340 2049400000000 2049400000000 0 0 16470362268400 53041 1123584027070855708721216766866

    # echo "==> 19 swap"
    # #depostToken depostAmount amountIn amountOutMinimum ### liquidity tickCurrent sqrtRatioX96 token0BalanceAmount token1BalanceAmount
    # swap $token1 1485050200000000 1485050200000000 909090550569 1250435266521266 99067 11220156202796378238345461253400 999997953081608364 998509068363031684

    # echo "==> 20 swap"
    # #depostToken depostAmount amountIn amountOutMinimum ### liquidity tickCurrent sqrtRatioX96 token0BalanceAmount token1BalanceAmount
    # swap $token0 1011995000000 1011995000000 1347093299165243 529634421680 44143 720104365939390610499544462530 999996941086608364 999990870992113452

    # echo "==> 21 decrease"
    # #positionId liquidity amount0Min amount1Min ###  liquidity tickCurrent sqrtRatioX96
    # decrease 1 132408605420 666394000 1099859408249 397225816260 44143 720104365939390610499544462530

    # echo "==> 22 swap"
    # #depostToken depostAmount amountIn amountOutMinimum ### liquidity tickCurrent sqrtRatioX96 token0BalanceAmount token1BalanceAmount
    # swap $token0 29300000000 29300000000 1314921229992 397225816260 33905 431611857389378483182039517039 999996914047140782 999993504250499568

    # echo "==> 23 increase"
    # depost $token0 20300000000
    # depost $token1 1244701317746
    # #positionId amount0Desired amount0Min amount1Desired amount1Min ### liquidity tickCurrent sqrtRatioX96
    # increase 1 20300000000 18227981755 1244701317746 1176893828604 639777973999 33905 431611857389378483182039517039

    # echo "==> 24 swap"
    # dfx canister call $dipAId approve "(principal \"$poolId\", $TOTAL_SUPPLY)"
    # dfx canister call $dipBId approve "(principal \"$poolId\", $TOTAL_SUPPLY)"
    # #depostToken depostAmount amountIn amountOutMinimum ### liquidity tickCurrent sqrtRatioX96 token0BalanceAmount token1BalanceAmount
    # swap $token1 515977001200000000 515977001200000000 282104104996 0 887271 1461446703485210103287273052203988822378723970341 999999996892295739 944931945772461540

    # echo "==> 25 swap"
    # #depostToken depostAmount amountIn amountOutMinimum ### liquidity tickCurrent sqrtRatioX96 token0BalanceAmount token1BalanceAmount
    # swap $token0 1000000000 1000000000 30792199830315 1250435266521266 104337 14602149588923138925101933711806 999999995892295739 944965817192274887

    # echo "==> 26 swap"
    # #depostToken depostAmount amountIn amountOutMinimum ### liquidity tickCurrent sqrtRatioX96 token0BalanceAmount token1BalanceAmount
    # swap $token1 33969900000000 33969900000000 906271879 1250435266521266 104339 14604295480606908301311147523433 999999996889194806 944931847292274887

    # echo "==> 27 swap"
    # #depostToken depostAmount amountIn amountOutMinimum ### liquidity tickCurrent sqrtRatioX96 token0BalanceAmount token1BalanceAmount
    # swap $token1 3435320000 3435320000 91635 1250435266521266 104339 14604295697617397560526319750504 999999996889295605 944931843856954887

    echo "==> withdraw reward fee"
    withdraw_reward_fee

    sleep 400

    echo "==> close farm"
    close_farm

    sleep 4000
};

test

dfx stop
mv dfx.json.bak dfx.json