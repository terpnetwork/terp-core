# Releases


## TLDR
> build wasmvm release artifacts
> build terp-core release artifacts
> build changelog and migration artifacts
> update all codebases with stateful/versioned data about terp network
> all repositories containing versioned info
> changelogs, CI & test assurance



- generate all documents without creating releases
- generate all releases without creating documents
- dry run of everything (tmp folder for writing documents)


proposal and release workflow:
- generate a folder with:
    - upgrade instructions
    - cosmovisor json (with actual artifacts for release)
    - software upgrade json creation
- add flag design so we can impement future features such as:
    - forking and pushing proposal folder info to git source
    - broadcasting proposal to various gateways
    - pinning metadata to ipfs
    - signing and broadcasting proposal


right now:
- make upgrade-guide:
    -  prints out to std iinstead of making folders. (we have networks/upgrades in terp-core to use )
    - asks for proposal id (we create this before proposal is broadcasted)

    release prep