open! Import

module Binable = Binable0

include Base.Hash_set_intf

module type S_plain = sig
  type elt
  type 'a hash_set
  type t = elt hash_set [@@deriving sexp_of]
  type 'a t_ = t
  type 'a elt_ = elt

  include Creators
    with type 'a t := 'a t_
    with type 'a elt := 'a elt_
    with type ('a, 'z) create_options := ('a, 'z) create_options_without_hashable

  module Provide_of_sexp(X : sig type t [@@deriving of_sexp] end with type t := elt)
    : sig type t [@@deriving of_sexp] end with type t := t
  module Provide_bin_io(X : sig type t [@@deriving bin_io] end with type t := elt)
    : sig type t [@@deriving bin_io] end with type t := t
end

module type S = sig
  include S_plain
  include sig type t [@@deriving of_sexp] end with type t := t
end

module type S_binable = sig
  include S
  include Binable.S with type t := t
end
