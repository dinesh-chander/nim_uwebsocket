## Compatibility export module for fast hash helpers.
## Re-export the shared implementation from nim_usockets so both layers
## use the same FastMap/FastSet types.

import ../../../nim_usockets/src/nim_usockets/fast_hash

export fast_hash
