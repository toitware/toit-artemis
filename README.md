# Artemis

This package provides extra functionality for containers
managed by Artemis.

----------------

# Example

Install this package using:

``` sh
toit.pkg install artemis
```

and use it from your programs:

```
import artemis

main:
  if artemis.is_enabled:
    print "Running on Artemis $artemis.version"
```
