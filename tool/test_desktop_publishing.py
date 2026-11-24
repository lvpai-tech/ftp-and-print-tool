from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock, patch

from package_release import write_release_info
from publish_desktop_update import CHANNELS, package_metadata, upload_parts


class DesktopPublishingTest(unittest.TestCase):
    def test_selected_channel_and_exact_build_bytes_match_on_both_platforms(self):
        with TemporaryDirectory() as scratch:
            directory = Path(scratch)
            for channel in CHANNELS:
                for platform, suffix, setup in (
                    ("windows-x64", "-setup.exe", True), ("macos-arm64", ".dmg", False),
                ):
                    with self.subTest(channel=channel, platform=platform):
                        package = directory / f"lvpai-ftp-0.4.5-9-{platform}{suffix}"
                        package.write_bytes(b"controlled package bytes")
                        info = directory / ("setup-release-info.json" if setup else "release-info.json")
                        write_release_info(info, package, version="0.4.5", code="9",
                                           platform=platform, channel=channel, setup=setup)
                        prefix, manifest = package_metadata(package, channel)
                        self.assertEqual(prefix, f"ftp-client/{channel}/{platform}" + ("/setup" if setup else ""))
                        self.assertEqual(manifest["versionCode"], 9)
                        for other in set(CHANNELS) - {channel}:
                            with self.assertRaisesRegex(ValueError, "selected update channel"):
                                package_metadata(package, other)
                        package.write_bytes(b"controlled changed bytes")
                        with self.assertRaisesRegex(ValueError, "differs from this package"):
                            package_metadata(package, channel)

    @patch("publish_desktop_update.PART_SIZE", 4)
    def test_multipart_preserves_order_and_disallows_overwrite_on_completion(self):
        with TemporaryDirectory() as scratch:
            package = Path(scratch) / "package"
            package.write_bytes(b"0123456789")
            client = Mock()
            client.create_multipart_upload.return_value = {"UploadId": "upload"}
            client.upload_part.side_effect = lambda **args: {"ETag": args["Body"].decode()}
            manifest = {"sizeBytes": 10, "sha256": "a" * 64}
            upload_parts(client, "bucket", "key", package, manifest)
            client.complete_multipart_upload.assert_called_once_with(
                Bucket="bucket", Key="key", UploadId="upload", ForbidOverwrite="true",
                MultipartUpload={"Part": [
                    {"PartNumber": 1, "ETag": "0123"},
                    {"PartNumber": 2, "ETag": "4567"},
                    {"PartNumber": 3, "ETag": "89"},
                ]},
            )
            self.assertTrue(all(call.kwargs["EnableMD5"] for call in client.upload_part.call_args_list))
            client.abort_multipart_upload.assert_not_called()

    def test_multipart_failure_aborts_without_completing(self):
        with TemporaryDirectory() as scratch:
            package = Path(scratch) / "package"
            package.write_bytes(b"incomplete")
            client = Mock()
            client.create_multipart_upload.return_value = {"UploadId": "upload"}
            client.upload_part.side_effect = IOError("network failed")
            with self.assertRaisesRegex(IOError, "network failed"):
                upload_parts(client, "bucket", "key", package, {"sizeBytes": 10, "sha256": "a" * 64})
            client.complete_multipart_upload.assert_not_called()
            client.abort_multipart_upload.assert_called_once_with(Bucket="bucket", Key="key", UploadId="upload")
