# ICPSwap Farm

The code is written in Motoko and developed in the DFINITY command-line execution [environment](https://internetcomputer.org/docs/current/references/cli-reference/dfx-parent). Please follow the documentation [here](https://internetcomputer.org/docs/current/developer-docs/setup/install/#installing-the-ic-sdk-1) to setup IC SDK environment and related command-line tools.  

## Introduction

**FarmController**

This actor is mainly responsible for creating a reward farm. The admin can call the create function to create a valid reward farm. The validity verification mainly includes: the reward amount *rewardAmount* must be a positive number, the validity of the farm start time *startTime* and end time *endTime*, and the farm duration’s validity, the validity of the reward distribution cycle *secondPerCycle* relative to the duration, the reward token *rewardToken* in the farm must exist in the *rewardPool* formed by it and the platform currency icp, etc.

**Farm**

This actor mainly includes the following three parts of business functions, which will be introduced separately below.

The first part is the pledge-related logic: users can call the *stake* function to pledge the *_swapPoolAct* related liquidity voucher tokens specified in the farm to obtain reward tokens. Since the voucher position contains the price range, if the farm has turned on the price limit, then only positions within the valid price range can be pledged, and qualified positions will be transferred to the farm for pledge; later, the user can call the *unstake* function to unstake, and the contract will return the user's pledged tokens and Issue the user's staking rewards; in addition, *feeReceiverCid* can call *withdrawRewardFee* to obtain the staking reward handling fee.

The second part is the logic related to reward calculation: each farm sets a timer, and regularly calls the *_distributeReward* function to update the user's reward in each time period. The total reward amount of the farm in each cycle is fixed. At each reward update, the actor will calculate the overall reward weight based on whether the price limit is turned on and the liquidity of all users' pledged positions, and then based on the liquidity of the user's single pledged position. and time to calculate its reward amount and update it.

The third part is the status management of the farm. There are four statuses of the farm, namely *#NOT_STARTED*, *#LIVE*, *#FINISHED*, *#CLOSED*. When there is no user staking in the farm, the admin can call the close function to set the farm status to *#CLOSED*, and recycle the remaining unallocated reward tokens to the refunder address; the admin can also call the *finishManually* function to set the farm status to *#FINISHED*; the admin can also call the *restartManually* function to reset the farm status to *#LIVE*, at which time the user can continue staking, etc.

**FarmFeeReceiver**

This actor is responsible for the management of pledge fees and is mainly divided into two parts of business logic functions. All logic can only be called by addresses with Controller permissions. The first part is that the Controller can call the *claim* function to withdraw the pledge fees accumulated in the farm. The second part is that the Controller can call the transfer and *transferAll* functions to transfer the fee tokens to other addresses. The token standards supported by this actor include DIP20, DIP20-WICP, DIP20-XTC, EXT, ICRC1, ICRC2, ICRC3, and ICP.

## Local Testing

Run the `test-flow.sh` script to see how the whole process is working.

```bash
sh test-flow.sh
```

In the script, we use some external canisters to make the whole swap process run.

Data collection canister:
 - base_index
 - node_index
 - price

Token canister:
 - DIP20A
 - DIP20B
 - ICRC2

Tool canister:
 - Test

Regarding these canisters, only the data collection canisters are self-developed by ICPSwap, the rest can be found in the current project, or other projects that have been open-sourced in IC ecosystem. We have a plan to open source this part of the code later, for now, please use the compiled wasm and did files in the current project.

When running the `test-flow.sh` script for the first time, in order to shorten the testing time, we use shorter pledge duration and distribution cycle. So we can find the function *create* in FarmController.mo.

Comment out these lines:

```motoko
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
} else if (duration >= SIX_MONTH) {
    if (args.secondPerCycle < TWELVE_HOURS) {
        return #err("The reward distribution cycle cannot be faster than 12 hours");
    };
} else if (duration >= ONE_MONTH) {
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
```

Then the test script will run successfully.