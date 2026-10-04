{ self }:
let
  components = {
    iota = import ./iota.nix { inherit self; };
    omikron = import ./server.nix {
      inherit self;
      name = "omikron";
    };
    omega = import ./server.nix {
      inherit self;
      name = "omega";
    };
    client = import ./client.nix { inherit self; };
  };
in
components
// {
  default = {
    imports = builtins.attrValues components;
  };
}
