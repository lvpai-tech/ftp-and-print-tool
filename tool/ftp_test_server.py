"""Only bind loopback; keep uploads in a temporary directory until shutdown."""
import tempfile

from pyftpdlib.authorizers import DummyAuthorizer
from pyftpdlib.handlers import FTPHandler
from pyftpdlib.servers import FTPServer


def main():
    with tempfile.TemporaryDirectory(prefix="lvpai-ftp-") as root:
        authorizer = DummyAuthorizer()
        authorizer.add_user("test-user", "test-password", root, perm="elradfmwMT")
        FTPHandler.authorizer = authorizer
        server = FTPServer(("127.0.0.1", 0), FTPHandler)
        print(f"FTP_TEST_PORT={server.socket.getsockname()[1]}", flush=True)
        print("Stop with Ctrl+C. Uploaded test files will be removed.", flush=True)
        try:
            server.serve_forever()
        finally:
            server.close_all()


if __name__ == "__main__":
    main()
