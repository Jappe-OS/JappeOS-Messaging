# Versioning
Information and rules on giving a tag/release a version number.

## Syntax
**Versioning syntax: phase+major.minor.patch**

 - Syntax does not work like decimal numbers. Major, minor, and patch numbers do not have any limit. **Example: the version 1.1.55 is newer than 1.1.6.**
 - The **major** version cannot go under 1, meaning the first version is 1.0.0.
 - The version number has to always contain a **phase**.

### Possible phases
*Dev first, release last.*

 1. **dev**: Still fully in development, should be a somewhat working product (when releasing a dev build).
 2. **alpha**: Still in heavy development, may contain many bugs. Little to no testing has been done. Multiple features may still be missing.
 3. **beta**: (Bug test phase) Feature complete, may contain a lot of unknown & known bugs.
 4. **release**: The final release version. All known bugs fixed, fully feature complete.

### Major, Minor and Patch
 1. The **major** version number will be increment when incompatible API changes are made.
 2. The **minor** version number will be increment when new functionality is added in a backward compatible manner.
 3. The **patch** version number will be increment when backward compatible bug fixes are made.
