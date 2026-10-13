# The source file a compile_commands.json entry compiles (its last source
# argument; some commands end with flags), as an absolute path.
import os

SOURCE_EXTENSIONS = (".cpp", ".cc", ".cxx", ".c", ".mm", ".m", ".S", ".s")
VALUE_FLAGS = {"-o", "-include", "-MF", "-MT", "-MQ", "-x", "-isystem", "-I", "-iquote"}


def tu_source(entry):
    argv = entry["arguments"]
    for i in range(len(argv) - 1, 0, -1):
        if argv[i].endswith(SOURCE_EXTENSIONS) and argv[i - 1] not in VALUE_FLAGS:
            return os.path.normpath(os.path.join(entry["directory"], argv[i]))
    return os.path.normpath(os.path.join(entry["directory"], entry["file"]))
