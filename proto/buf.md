# Protobufs

This is the public protocol buffers API for [Terp-Core](https://github.com/terpnetwork/terp-core).

## Download

The `buf` CLI comes with an export command. Use `buf export -h` for details

#### Examples:

Download cosmwasm protos for a commit:
```bash
buf export buf.build/terpnetwork/terp-core:${commit} --output ./tmp
```

Download all project protos:
```bash
buf export . --output ./tmp
```