# Validation subDAO Proposal: Temperature Check for 90u-2 Testnet Launch Procedures

The PR containing the details on the 90u-2 test-net upgrade steps can be found here: https://github.com/terpnetwork/test-net/pull/6


# Upgrade Timeline

## I. Genesis File Modification [July 12th - July 15th]

There are two ways to participate as a node operator during the launch of 90u-2. To participate as a validator node requires the participant to have an inital `terpx` balance, but to participate as a full node, seed node, or light client does not. 

This first step allows any new contributors to add a genesis account balance of their own so that they may be able to participate as a genesis validator for 90u-2. 

### **Adding Genesis Accounts**

### Step 1: Fork the test-net Repo on Github

*If you are new to github workflows, feel free to checkout this guideline for managing forked repo's & Pull Request's (PR's) [link.](https://opensource.com/article/19/7/create-pull-request-github)*

### Step 2: Build the Terpd Daemon locally

Make sure you have setup your computers local enviroment with the prerequisites needed, dependent on your operating platform (Windows, Linux, MacOS).

**Prerequisites:** Make sure to have [Golang >=1.20](https://golang.org/).

#### Go setup

Follow the instructions [here](https://go.dev/doc/install) to install Go.

For an Ubuntu, you can probably use:
```
wget https://golang.org/dl/go1.20.5.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.20.5.linux-amd64.tar.gz
```

Unless you want to configure in a non standard way, then set these in the .profile in the user's home (i.e. ~/) folder.

```bash
export GOROOT=/usr/local/go
export GOPATH=$HOME/go
export GO111MODULE=on
export PATH=$PATH:/usr/local/go/bin:$HOME/go/bin
```

Source update .profile

```sh
source .profile
```
To Download the source file for `terpd`:
```bash
git clone https://github.com/terpnetwork/terp-core.git
cd terp-core || return
git checkout barberry
make install
```

You can verify the terpd correct version by checking this info:
```
name: terp
server_name: terpd
version: barberry
commit: d70c39066afda3800080a85a66ad018b63b4929c
```
### Step 3: Import or generate new keyring
To import a mnemonic that already exist:
```bash
terpd keys add <your-key-name> --recover
```
To generate a new keyring:
```bash
terpd keys add <your-key-name>
```
Make sure if you are generating a new keyring, you write down the mnemonic & public wallet addresses generated, so that you may reference it for the next steps. 

### Step 4: Download Genesis File

With terpd installed, lets initialize a new node structure:
```bash
terpd init <your-node-name>
```
This will generate a folder by default located at `~/.terp`. We can now download the genesis file configured for 90u-2 to our nodes, replacing the default one generated when we ran the command `terpd init`. 

To replace the genesis file, we recommend pulling from the forked repo you gereated on step-1:

NOTE: Replace <YOUR_GITHUB_ACCOUNT> with the username of the github account used to fork the repo.
```bash
curl -s https://raw.githubusercontent.com/<YOUR_GITHUB_ACCOUNT>/test-net/master/90u-2/prelaunch-genesis.json > $HOME/.terp/config/genesis.json
```

You can verify the genesis file is the correct version by checking the sha256sum, before following step 5:
```bash
cd test-net/90u-2/data \
sha256sum prelaunch-genesis.json
```
This command should return: `9a4dc95f5a45112b650b529c720a265d39358f2e146547c110353a49e735fff5  prelaunch-genesis.json`. If this is not the correct output, please remove the test-net folder and repeat Step 4. 

### Step 5: Add Genesis Account 

Now with the `90u-2` pre-genesis file configured to your node, we can now add genesis accounts to the genesis file:
```bash
terpd genesis add-genesis-account <your-public-terp-wallet-address> 1000000uterpx,1000000uthiolx

## Ex: terpd genesis add-genesis-account terp1574689mrmzv9mtsrw4l2wtln4edkzw68x96h6j 1000000uterpx,1000000uthiolx
```
Notice that each account will allocate only 1000000uterpx & 1000000uthiolx (1 TERPX & THIOLX each)

### Step 6: Open a New PR to the [Test-Net Repository](https://github.com/terpnetwork/test-net)

Once your have added your genesis account added, open up a new PR to include the addition to the genesis file you have made. You will need to copy the modified genesis file, located at `~/.terp/config/genesis.json` to your forked repo. 

To learn more about opening PR's you can learn more [here.](https://opensource.com/article/19/7/create-pull-request-github)

## II. Genesis Transaction Creation [July 16th - July 19th]

The next step in the timline is to generate gentx's, which are essentially a transaction made by each validator to be a part of the active set when the first block of the network is generated. This can only be done where each gentx signer is signing an identical genesis file. 

### Generate gentx file
Add your account to your local genesis file with a given amount and the key you just created. Use only 1000000uterpx, other amounts will be ignored.
```bash
terpd genesis gentx <key-name> 1000000uterpx --chain-id 90u-2 
```
### Copy the generated gentx json file to <repo_path>/90u-2/gentx/
```bash
cd test-net
cp ~/.terp/config/gentx/gentx*.json ./90u-2/gentx/
```
### Commit and push to your repo

### Create a PR onto https://github.com/terpnetwork/test-net

## III. Genesis Launch of 90u-2 [July 21st]

The final step is to distribute the finalized genesis file, and have peers connect with each other in preparation of blocks producing on 90u-2



**BY VOTING YES**, you agree these steps can be used to resume migrating to `90u-2`. \
**BY VOTING NO**, you do not agree these steps can be used to resume migrating to `90u-2`. 
