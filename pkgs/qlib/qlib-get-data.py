"""Download Qlib's prebuilt datasets (CLI for qlib.tests.data.GetData).

pyqlib's wheel ships the downloader but not upstream's scripts/get_data.py
entry point, so this exposes it the same way:

    qlib-get-data qlib_data --target_dir ~/.local/share/qlib/cn_data --region cn --interval 1d
"""

import fire
from qlib.tests.data import GetData

if __name__ == "__main__":
    fire.Fire(GetData)
