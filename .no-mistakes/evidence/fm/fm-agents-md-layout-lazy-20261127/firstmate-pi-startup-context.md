# Firstmate startup request

Pi 1.5.0 ran Firstmate's tracked startup extension against separate disposable checkouts and homes. The local OpenAI-compatible endpoint captured the outbound system message on the first turn. An enclosing copy of the repository instructions appeared in both requests and was identical in both. The checkout instruction sizes below measure the additional `AGENTS.md` block selected by Pi.

| Checkout | Selected instruction bytes | Total system message bytes with checkout path normalized | Per-path entries in startup | Pi exit |
| --- | ---: | ---: | ---: | ---: |
| 86a565ae | 82,122 | 147,797 | 100 | 0 |
| 4a0f90b0 | 63,650 | 129,325 | 0 | 0 |

The target sent 18,472 fewer bytes of startup instructions. Both sessions completed Firstmate startup. The target's layout section begins with this instruction.

```text
Use [docs/configuration.md](docs/configuration.md#per-path-listing) as needed for the operational-home layout, per-path listing, and configuration schemas.
```
