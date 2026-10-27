"""Stack adapters: per-language rules behind one interface. Rust first."""


class Adapter:
    name = ""


class RustAdapter(Adapter):
    name = "rust"


ADAPTERS = {"rust": RustAdapter}
