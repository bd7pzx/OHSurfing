"""Check the CDC-Checksum implementation against standard MD5 vectors."""
from pathlib import Path
import subprocess
import tempfile


source = (Path(__file__).resolve().parents[1] /
          "entry/src/main/cpp/core/src/NetClient.c").read_text(encoding="utf-8")
part = source.split("static uint32_t rol", 1)[1].split("typedef struct", 1)[0]
code = (
    "#include <stdint.h>\n#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n"
    + "static uint32_t rol" + part
    + '''int main(void) {
      const char* input[] = {"", "abc", "message digest", "abcdefghijklmnopqrstuvwxyz"};
      const char* expected[] = {
        "d41d8cd98f00b204e9800998ecf8427e",
        "900150983cd24fb0d6963f7d28e17f72",
        "f96b697d7cb7938d525a2f31aaf161d0",
        "c3fcd3d76192e4007dfb496cca67e13b"};
      for (int i=0; i<4; i++) {
        char hash[33] = {0};
        md5((const unsigned char*)input[i], strlen(input[i]), hash);
        if (strcmp(hash, expected[i])) { fprintf(stderr, "%s != %s\\n", hash, expected[i]); return 1; }
      }
      return 0;
    }
'''
)
with tempfile.TemporaryDirectory() as temporary:
    path = Path(temporary)
    (path / "test.c").write_text(code, encoding="utf-8")
    subprocess.run(["gcc", "-std=c11", str(path / "test.c"), "-o", str(path / "test.exe")], check=True)
    subprocess.run([str(path / "test.exe")], check=True)
print("CDC-Checksum MD5: 4 vectors passed")
