# The text-note header line the Mac reads, copied from the life tracker's
# dictation intake. check_artefacts.sh reads HEADER_TS from this file unless
# LTCAP_LIFE_TRACKER points at a life tracker checkout, in which case it reads
# the live definition there.
import re

HEADER_TS = re.compile(r"^\s*(\d{4})-(\d{2})-(\d{2})[ T](\d{1,2}):(\d{2})(?::\d{2})?\s*$")
