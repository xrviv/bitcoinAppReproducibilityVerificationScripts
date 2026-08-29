# Adversarial tests for the Sparrow MSI comparator

`msicmp.py` here is the same file `sparrowwindows_build.sh` embeds; the script's
`write_comparator` emits it byte-for-byte.

`advtest.py` builds mutated fixtures from three real extractions and asserts the
comparator's exit code and message. Run it as:

    python3 advtest.py <official-extract> <build-a-extract> <build-b-extract>

Each extract directory is produced by `7z x -tCompound <installer>.msi -o<dir>`.
Two of the three must be independent builds of the same source, so the positive
case has something legitimately equivalent to pass.

Exit codes under test: 0 equivalent, 1 real differences, 2 comparator/tool error.
