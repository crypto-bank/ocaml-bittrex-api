module type HTTP_CLIENT = sig
  include Cohttp.S.IO

  val get : string -> (string * string) list ->
    (Yojson.Safe.json -> [`Error of string | `Ok of 'a ]) -> 'a t

  (* val post : Credentials.t -> string -> (string * string) list -> *)
  (*   (string -> [< `Error of string | `Ok of 'a ]) -> 'a t *)
end

module type JSONABLE = sig
  type t
  val to_yojson : t -> Yojson.Safe.json
  val of_yojson : Yojson.Safe.json -> [`Ok of t | `Error of string]
end

module Stringable = struct
  module Of_jsonable (T: JSONABLE) = struct
    let to_string t = T.to_yojson t |> Yojson.Safe.to_string
    let pp ppf t = Format.fprintf ppf "%s" (to_string t)
    let of_string s = Yojson.Safe.from_string s |> T.of_yojson
    let ts_of_json ts =
      try
        match ts with
        | `List ts ->
            begin
              try
                let ts = List.map
                    (fun t -> match T.of_yojson t with
                       | `Ok a -> a
                       | `Error s -> failwith s) ts
                in `Ok ts
              with Failure s -> `Error s
            end
        | _ -> `Error "Not a json array."
      with exn -> `Error (Printexc.to_string exn)
  end
end

module Bittrex (H: HTTP_CLIENT) = struct
  open H

  module Market = struct
    module Raw = struct
      module T = struct
        type t = {
          market_currency [@key "MarketCurrency"]: string;
          base_currency [@key "BaseCurrency"] : string;
          market_currency_long [@key "MarketCurrencyLong"] : string;
          base_currency_long [@key "BaseCurrencyLong"] : string;
          min_trade_size [@key "MinTradeSize"] : float;
          market_name [@key "MarketName"] : string;
          is_active [@key "IsActive"] : bool;
          created [@key "Created"] : string;
          notice [@key "Notice"] : string option;
          is_sponsored [@key "IsSponsored"] : bool option;
          logo_url [@key "LogoUrl"] : string option;
        } [@@deriving show,yojson]
      end

      include T
      include Stringable.Of_jsonable(T)

      let markets () = get "public/getmarkets" [] ts_of_json
    end
    include Raw
  end

  module Ticker = struct
    module Raw = struct
      module T = struct
        type t = {
          bid [@key "Bid"] : float;
          ask [@key "Ask"] : float;
          last [@key "Last"] : float;
        } [@@deriving show,yojson]
      end
      include T
      include Stringable.Of_jsonable(T)

      let ticker pair = get "public/getticker" ["market", pair] of_yojson
    end
    include Raw
  end

  module Currency = struct
    module T = struct
      type t = {
        currency [@key "Currency"] : string;
        currency_long [@key "CurrencyLong"] : string;
        min_confirmation [@key "MinConfirmation"] : int;
        tx_fee [@key "TxFee"] : float;
        is_active [@key "IsActive"] : bool;
        coin_type [@key "CoinType"] : string;
        base_addr [@key "BaseAddress"] : string option;
        notice [@key "Notice"] : string option;
      } [@@deriving show,yojson]
    end
    include T
    include Stringable.Of_jsonable(T)

    let currencies () = get "public/getcurrencies" [] ts_of_json
  end

  module OrderBook = struct
    type order = {
      qty [@key "Quantity"] : float;
      price [@key "Rate"] : float;
    } [@@deriving show,yojson]

    type book = {
      buy: order list;
      sell: order list
    } [@@deriving show,yojson]

    let book pair = get "public/getorderbook"
        ["market", pair; "type", "both"; "depth", "50"] book_of_yojson
  end
end

module Cryptsy (H: HTTP_CLIENT) = struct
  open H

  module Currency = struct
    module Raw = struct
      module T = struct
        type t = {
          id: string;
          name: string;
          code: string;
          maintenance: string;
        } [@@deriving show,yojson]
      end
      include T
      include Stringable.Of_jsonable(T)

      let currencies () = get "currencies" [] ts_of_json
    end

    type t = {
      id: int;
      name: string;
      code: string;
      maintenance: int;
    } [@@deriving show,yojson]

    let of_raw r = {
      id = int_of_string r.Raw.id;
      name = r.Raw.name;
      code = r.Raw.code;
      maintenance = int_of_string r.Raw.maintenance;
    }

    let currencies () = Raw.currencies () >>= fun ts -> return @@ List.map of_raw ts
  end

  module Market = struct

    type stats = {
      volume: float;
      volume_btc: float;
      price_high: float;
      price_low: float;
    } [@@deriving show,yojson]

    type last_trade = {
      price: float;
      date: string;
      timestamp: int;
    } [@@deriving show,yojson]

    module Raw = struct
      module T = struct
        type t = {
          id: string;
          label: string;
          coin_currency_id: string;
          market_currency_id: string;
          maintenance_mode: string;
          verifiedonly: bool;
          stats [@key "24hr"] : stats;
          last_trade: last_trade;
        } [@@deriving show,yojson]
      end
      include T
      include Stringable.Of_jsonable(T)

      let markets () = get "markets" [] ts_of_json
    end

    type t = {
      id: int;
      label: string;
      coin_currency_id: int;
      market_currency_id: int;
      maintenance_mode: int;
      verifiedonly: bool;
      stats : stats;
      last_trade: last_trade;
    } [@@deriving show,yojson]

    let of_raw t = {
      id = int_of_string t.Raw.id;
      label = t.Raw.label;
      coin_currency_id = int_of_string t.Raw.coin_currency_id;
      market_currency_id = int_of_string t.Raw.market_currency_id;
      maintenance_mode = int_of_string t.Raw.maintenance_mode;
      verifiedonly = t.Raw.verifiedonly;
      stats = t.Raw.stats;
      last_trade = t.Raw.last_trade;
    }

    let markets () = Raw.markets () >>= fun ts -> return @@ List.map of_raw ts
  end

  module Ticker = struct
    module Raw = struct
      module T = struct
        type t = {
          bid [@key "Bid"] : float;
          ask [@key "Ask"] : float;
          last [@key "Last"] : float;
        } [@@deriving show,yojson]
      end
      include T
      include Stringable.Of_jsonable(T)

      let ticker pair = get "public/getticker" ["market", pair] of_yojson
    end
    include Raw
  end
end
