"""autobcl2fastq configuration — re-exported from rsgutils.tools.autobcl2fastq.

All field definitions and defaults live in rsgutils so that ``rsgutils setup``
can configure them without this package being installed.
"""

from rsgutils.tools.autobcl2fastq import (  # noqa: F401
    XDG_CONFIG,
    XDG_DATA,
    XDG_STATE,
    BiomicsConfig,
    HPCConfig,
    Settings,
)

__all__ = ["BiomicsConfig", "HPCConfig", "Settings", "XDG_CONFIG", "XDG_DATA", "XDG_STATE"]
