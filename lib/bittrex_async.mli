open Bittrex_intf
open Async.Std

module Bitfinex : BITFINEX with type 'a t := 'a Deferred.t
module BTCE : BTCE with type 'a t := 'a Deferred.t
module Kraken : KRAKEN with type 'a t := 'a Deferred.t
