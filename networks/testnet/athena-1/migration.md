# CGAS IBC MIGRATION STEPS

## Timeline 

The following is details on the timeline of migrating resources to Terp Network:

* **Start of CGAS Migration: Sept 20, 2022**

* **End of CGAS Migration: Sept 27th, 2022**

All valiidators are encouraged to halt node operations on Chronic Network following Sept 27th, to allow community members the chance to migrate cgas tokens over. 


## Step 1: Turn on advanced IBC transfers in Keplr

<img width="362" alt="Advanced-ibc-transfers" src="https://user-images.githubusercontent.com/90259314/191427423-cc650b0b-67dc-4f29-bb81-b7c0943eb231.png">

## Step 2: Obtain your Terp Network wallet address


This will be located in the beta support tab of keplr wallet once succesfully connected to an application on the test-net [Link](https://terp-explorer.vercel.app/wallet/import).

Note that you will need to specify `Terp Chain` when selecting the various networks for keplr to connect to. All private keys & sentitive information is not shared with the vercel app. 

## Step 3: Obtain the IBC channel id

A link to the test-net ibc channel specs can be found [here](https://github.com/terpnetwork/test-net/blob/master/athena-1/relayers/README.md).

**The channel used from Chronic Chain to Terp-NET is channel-2.**


## Step 4: Using keplr, provide details of destination chain, destination address, channel-id, token denom & amount. 


## Step 5: Sign and send the transaction
