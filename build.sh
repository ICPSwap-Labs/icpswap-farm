#!/bin/bash

rm -rf .dfx

cp -R ./dfx.json ./dfx_temp.json

echo "==> build Farm..."

cat <<< $(jq '.canisters={
  FarmFactory: {
    "main": "./src/FarmFactory.mo",
    "type": "motoko"
  },
  "FarmFeeReceiver": {
    "main": "./src/FarmFeeReceiver.mo",
    "type": "motoko"
  },
  Farm: {
    "main": "./src/Farm.mo",
    "type": "motoko"
  },
  FarmFactoryValidator: {
    "main": "./src/FarmFactoryValidator.mo",
    "type": "motoko"
  }
}' dfx.json) > dfx.json
dfx start --background

dfx canister create --all
dfx build --all
dfx stop
rm ./dfx.json
cp -R ./dfx_temp.json ./dfx.json
rm ./dfx_temp.json
