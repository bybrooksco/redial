"""One object that looks like the old single-file daemon, for the tests.

The daemon is split across redial/*.py, and a module that does `from .log import log` holds its own
binding. A test that stubs `m.log` has to reach all of them, or the code under test keeps calling
the real one. So: reading a name gives the module that defines it; setting or deleting a name does
it in every redial module that has it.
"""

import ast
import sys


def _defined_names(path):
    """Top-level names a module assigns itself (not imports), plus its `global` rebinds."""
    tree = ast.parse(open(path).read())
    names = set()
    for node in tree.body:
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            names.add(node.name)
        elif isinstance(node, (ast.Assign, ast.AnnAssign, ast.AugAssign)):
            for t in node.targets if isinstance(node, ast.Assign) else [node.target]:
                names.update(n.id for n in ast.walk(t) if isinstance(n, ast.Name))
    for node in ast.walk(tree):
        if isinstance(node, ast.Global):
            names.update(node.names)
    return names


class DaemonView:
    def __init__(self, main):
        mods = [mod for name, mod in sorted(sys.modules.items()) if name.split(".")[0] == "redial" and mod]
        home = {}
        for mod in mods:
            for name in _defined_names(mod.__file__):
                home.setdefault(name, mod)
        object.__setattr__(self, "_main", main)
        object.__setattr__(self, "_mods", mods)
        object.__setattr__(self, "_home", home)

    def _owner(self, name):
        return self._home.get(name, self._main)

    def __getattr__(self, name):
        owner = self._owner(name)
        if name in vars(owner):
            return vars(owner)[name]
        for mod in self._mods:
            if name in vars(mod):
                return vars(mod)[name]
        raise AttributeError(name)

    def __setattr__(self, name, value):
        setattr(self._owner(name), name, value)
        for mod in self._mods:
            if name in vars(mod):
                setattr(mod, name, value)

    def __delattr__(self, name):
        found = False
        for mod in self._mods:
            if name in vars(mod):
                delattr(mod, name)
                found = True
        if not found:
            raise AttributeError(name)

    @property
    def __dict__(self):
        merged = {}
        for mod in reversed(self._mods):
            merged.update(vars(mod))
        for name, mod in self._home.items():
            if name in vars(mod):
                merged[name] = vars(mod)[name]
        return merged
