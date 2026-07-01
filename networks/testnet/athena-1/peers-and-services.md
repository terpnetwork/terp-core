### Note: Please feel free to create a new PR to add to this list & keep track of all things provided by our lovely validators :)
# Terp Network peers, seed & services
For the **Chain Registry** from Cosmos [GitHub](https://github.com/cosmos/chain-registry/tree/master/terpnetwork) we'd like to gather some endpoints and 
persistent peers from our most valuable users.

 Please provide your public ***endpoints*** and/or ***persistent_peers*** .It is greatly appreciated.

 # Address_Book
 ```
 curl -s https://snapshots2-testnet.nodejumper.io/terpnetwork-testnet/addrbook.json > $HOME/.terp/config/addrbook.json
 ``` 

# Persistent_peers
```
* peers="15f5bc75be9746fd1f712ca046502cae8a0f6ce7@terp-testnet.nodejumper.io:30656,65f819851e9eb2484818cb7d12f4edd759a1223a@65.21.143.79:25856,86a64042d8f3508b7d553e36413eade045d3a985@207.180.206.3:11656,82aa920c9b74be25cbeafa027206516b40784137@95.217.234.243:26656,74a37dda6fe3b8c88630b8e2eb808abccba14a44@65.21.131.215:26636,abf05e076f72192c0f45c3e6cef9f5bd285fac4b@65.21.151.93:46656,d6d7e96122f61a3a2216df9a74822171489a0e17@65.109.17.86:34656,1f5b5de284d47acd69ba73461fb6894a051bec59@51.75.88.124:26656,84d770b9c4d10c734fd9ec5753ab19d4693ecbcd@116.202.236.115:21316,a4f76a1c232dece6aa80ba9ada569d3355111c69@78.46.16.236:47656,ff2ee3da5675de1dcd25aca8d7958d9a0b439f55@185.237.252.152:36656,f9d7b883594e651a45e91c49712151bf93322c08@141.95.65.26:29456,c2a177164098b317261d55fb1c946a97e5e35adb@75.119.134.69:30656,2e4e0f43100b424dc4b27e478acc39bebe32344d@77.37.176.99:55656,63910944ee1c3dd7ae683cc4b96241bcf059c08f@167.99.0.78:26656,3786f8392cf865c8fd4f599f30f5047c33977432@135.181.221.186:29656,7e5c0b9384a1b9636f1c670d5dc91ba4721ab1ca@195.201.218.107:36656,c583c0a09ba50fb2eef6cb665dbdea1e5b790ffd@161.97.167.120:20656,88497ab3bbbcc1e8545771f45020e738bcce590f@46.138.245.164:26465,3122336186c16b9ba7f309afbac06412183121f8@65.108.103.86:56656,a24cbc18af3f3558719e2f479ff412f60e126683@181.41.142.78:11504,a6fe56d1c57d2edb7cc6ec638ccdcbc2f8ad2813@65.108.206.56:39656,c989593c89b511318aa6a0c0d361a7a7f4271f28@65.108.124.172:26656,2c7cef934ae39bc6a2fb240b4bfb2c3e0ba0be4e@193.46.243.184:36656,e95eaf418dc2e61437f1b514eda666cd20949571@149.102.143.147:46656,9c11526f00ae0bffee82209118b27736fca8c7ba@195.3.222.161:33656,14ca69edabb36c51504f1a760292f8e6b9190bd7@65.21.138.123:28656,d2af3d86ee5698037d802567ed930f8d58d89c25@38.242.199.93:16656,9b0c5af3f13fe8ca3d0a89d5752e8f5f9062ce7c@95.216.168.99:60656,7cd2881b35643352deed6ec283727c3d05be7502@38.242.214.172:11656,1026fa01cbf0640bb2f2cb20e253997bf51c1858@85.173.113.198:20656,c8566ae397962bd6b150db94489442957e8bac72@65.109.61.47:15656,166939372c24934c2227cf9c1f1aaa0bd55510bf@161.97.157.15:26656,681114e96b155d0fe874dc841a66d11d75a68738@176.241.136.91:26656,25698175170dc9634a851b3ae797d9e417f78491@213.136.92.19:26656,aff25de278af66d060a5f130ec90d6b6069c328c@65.21.251.128:33656,726e9f00ecd575365f5a83f484ebf66bb8eccb72@45.8.133.71:11656,bdeac776f6c7ceb78af9c8f3d29f88757f289a17@95.217.224.252:29656,59a370e401c64a3df8dfb245a7e58b28bc1c2df0@38.242.152.170:26656,cab8b1969eadc8288b5178c814645e6e8c944a82@185.241.151.174:26656,e1fbb034e9d579ec4012ea8e5bae69887020d06f@176.9.146.72:60756,fa0b9020eac4bf9670949bd87809055bf413798d@75.119.128.218:11656,5614064b54a36d4467ace382a27b8242bb0053d1@74.207.226.78:26656,e822712f22651c5e50484afb30c68f9615a31ed9@77.121.209.191:11656,99c9429569978e599c476cf6e35eaccc492f58a2@97.84.107.110:26656,f4199c24046325746548e0cb46b11637dfb447d3@95.217.121.229:11014,08a0f07da691a2d18d26e35eaa22ec784d1440cd@194.163.164.52:56656,e6630d7bcc1c6c9593fdcb7e7e1fb762b3e257d1@65.21.134.202:26636,5a6f4f80c7a29055028fc503216a1539594ad33f@89.111.15.146:11514"
sed -i 's|^persistent_peers *=.*|persistent_peers = "'$peers'"|' $HOME/.terp/config/config.toml
```


# Seeds
* 9cf4fc01e035182688a893d6f6c4687cb59d603d@138.201.200.159:11503 

# Snapshots
* [High-Stakes](https://tools.highstakes.ch/snapshots/terp)

# StateSync Servers and instructions:
* https://nodejumper.io/terpnetwork-testnet/sync#snap
## StateSync Server Setup Instructions:
* https://github.com/terpnetwork/

### Terp Network Docs
* https://docs.terp.network

###  Faucet
* TBD

### snapshot service info 
* TBD


[# RPCs, LCD, GRPC and other endpoints/services](/peers_seeds_and_services.md)

```json 
{
  "apis": {
    "rpc": [
    {
        "address": "23.88.53.28:36657",
        "provider": "HighStakes"
    },
    {
        "address": "https://rpc-terp.zenchainlabs.io/",
        "provider": "Zenchain Labs"
    },
    {
        "address": "https://terp-rpc.skynetvalidators.com/",
        "provider": "Skynet Validators"
    },
     {
        "address": "https://terp-testnet.nodejumper.io ",
        "provider": "NodeJumper"
    },
    {
        "address": "https://terp.rpc.bccnodes.com/ ",
        "provider": "BccNodes"
    },
    {
        "address": "https://terp-testnet.rpc.kjnodes.com/",
        "provider": "KjNodes"
    },
    {
        "address": "https://rpc-t.terp.nodestake.top/ ",
        "provider": "NodeStake.top"
    }
    ],
    "grpc": [
    {
        "address": "23.88.53.28:36090",
        "provider": "HighStakes"
    },
    {
        "address": "https://grpc-t.terp.nodestake.top/",
        "provider": "Nodestake.top"
    }
      ],
    "rest": [
    {
        "address": "https://api-terp.zenchainlabs.io/",
        "provider": "ZenchainLabs"
    },
    {
        "address": "https://terp-api.skynetvalidators.com",
        "provider": "SkynetValidators"
    },
    {
        "address": "https://terp-testnet.nodejumper.io:1317",
        "provider": "NodeJumper"
    },
    {
        "address": "https://terp.api.bccnodes.com/ ",
        "provider": "Bccnodes"
    },
    {
        "address": "https://terp-testnet.api.kjnodes.com/",
        "provider": "KjNodes"
    },
    {
        "address": "https://api-t.terp.nodestake.top/",
        "provider": "NodeStake"
    },
    {
        "address": "",
        "provider": ""
    }
    ]
  }
```
