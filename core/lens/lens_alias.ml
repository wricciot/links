open Lens_utility

type t = string

module Map = struct
  include Utility.StringMap

  let find t ~key =
    find_opt key t
end

module Set = struct
  include String.Set

  let pp_pretty fmt cs =
    List.iter (fun c -> Format.fprintf fmt "%s " c) (elements cs)
end