open Rresult
open Mt
open Bittrex_intf

module type JSONABLE = sig
  type t [@@deriving yojson]
end

let yojson_of_string s =
  try Ok (Yojson.Safe.from_string s) with
  | Yojson.Json_error str -> Error (`Json_error str)

module Stringable = struct
  module Of_jsonable (T: JSONABLE) = struct
    let of_yojson s = T.of_yojson s
                      |> R.of_presult
                      |> R.reword_error (function msg -> `Json_error msg)

    let to_string t = T.to_yojson t |> Yojson.Safe.to_string
    let pp ppf t = Format.fprintf ppf "%s" (to_string t)
    let of_string s = R.(yojson_of_string s >>= of_yojson)
    let ts_of_json = function
      | `List ts ->
        begin
          try
            let ts = CCList.filter_map
                (fun t -> match of_yojson t with
                   | Ok a -> Some a
                   | Error (`Json_error msg) -> failwith msg)
                ts
            in Ok ts
          with Failure msg -> Error (`Json_error msg)
        end
      | json -> Error (`Json_error (Yojson.Safe.to_string json))
  end
end

module Int64 = struct
  include Int64
  let ( * ) = mul
  let ( + ) = add
  let ( / ) = div
end

module Bitfinex (H: HTTP_CLIENT) = struct
  include H
  type symbol = [`XBTUSD | `LTCUSD | `LTCXBT]
  type exchange = [`Bitfinex | `Bitstamp]
  type ticker = (int64, int64) Ticker.Tvwap.t
  type book_entry = int64 Tick.T.t
  type trade = < p : int64; v : int64; side : [`Buy | `Sell]; ts : int64 >
  type nonrec credentials = credentials
  type position = < id : int; p : int64; pl : int64;
                    status : [`Active | `Unset ];
                    swap : int64; symbol : symbol; ts : int64;
                    v : int64 >
  type order
  type order_status =
    < avg_fill_price : int64;
      exchange : Exchange.t;
      exchange_order_id : string;
      expire_ts : int64;
      filled_qty : int64;
      order_qty : int64;
      order_type : [ `Limit | `Market
                   | `Market_if_touched | `Stop | `Stop_limit ];
      p1 : int64;
      p2 : int64;
      side : [ `Buy | `Sell ];
      symbol : Symbol.t;
      time_in_force : [ `Fill_or_kill | `Good_till_canceled | `Good_till_date_time ]
    >
  type filled_order_status =
    < fee_amount : int64; fee_currency : Mt.Currency.t;
      order_id : string; p : int64; side : [ `Buy | `Sell ];
      symbol : symbol; tid : string; ts : int64; v : int64 >
  let kind = `Bitfinex
  let symbols = [`XBTUSD; `LTCUSD; `LTCXBT]

  let accept = function
    | `XBTUSD -> Some `XBTUSD
    | `LTCUSD -> Some `LTCUSD
    | `LTCXBT -> Some `LTCXBT
    | `XBTEUR -> None
    | `LTCEUR -> None
    | `XBTLTC -> None

  let symbol_of_string_exn symbol =
    CCOpt.(Symbol.of_string symbol >>= accept |> get_exn)

  let exchange_of_string_exn exchange =
    let accept_exchange = function
      | `Bitfinex -> Some `Bitfinex
      | `Bitstamp -> Some `Bitstamp
      | _ -> None in
    CCOpt.(Exchange.of_string exchange >>= accept_exchange |> get_exn)

  let price_increment = 1_000_000
  let trade_increment = 1

  let get endpoint params yojson_to_a =
    get endpoint params >>| fun s ->
    R.(s >>= yojson_of_string >>= yojson_to_a)

  let post creds endpoint body yojson_to_a =
    post creds endpoint body >>| fun s ->
    R.(s >>= yojson_of_string >>= yojson_to_a)

  let string_of_symbol = function
    | `XBTUSD -> "BTCUSD"
    | `LTCUSD -> "LTCUSD"
    | `LTCXBT -> "LTCBTC"

  let symbol_of_string_exn = function
    | "BTCUSD" -> `XBTUSD
    | "LTCUSD" -> `LTCUSD
    | "LTCBTC" -> `LTCXBT
    | _ -> invalid_arg "symbol_of_string_exn"

  let side_of_string = function
    | "buy" -> `Buy
    | "sell" -> `Sell
    | _ -> invalid_arg "buysell_of_string"

  let string_of_side = function
    | `Buy -> "buy"
    | `Sell -> "sell"

  let ot_tif_of_string = function
    | "market" -> `Market, `Good_till_canceled
    | "limit" -> `Limit, `Good_till_canceled
    | "stop" -> `Stop, `Good_till_canceled
    | "fill-or-kill" -> `Limit, `Fill_or_kill
    | _ -> invalid_arg "ot_tif_of_string"

  let string_of_ot_tif ~order_type ~time_in_force =
    match order_type, time_in_force with
    | `Market, `Good_till_canceled -> "market"
    | `Limit, `Good_till_canceled -> "limit"
    | `Stop, `Good_till_canceled -> "stop"
    | `Limit, `Fill_or_kill -> "fill-or-kill"
    | _ -> invalid_arg "string_of_ot_tif"

  let timestamp_of_string s =
    let ts = Bytes.make 19 '0' in
    Bytes.blit_string s 0 ts 0 10;
    Bytes.blit_string s 11 ts 10 String.(length s - 11);
    ts |> Bytes.unsafe_to_string |> Int64.of_string

  module Ticker = struct
    module T = struct
      type t = {
        mid: string;
        bid: string;
        ask: string;
        last_price: string;
        low: string;
        high: string;
        volume: string;
        timestamp: string;
      } [@@deriving yojson]
    end
    include T
    include Stringable.Of_jsonable(T)
    let ticker p = get ("/v1/pubticker/" ^ string_of_symbol p) [] of_yojson
  end

  let ticker p =
    let open Ticker in
    let of_raw r =
      let vwap = satoshis_of_string_exn r.mid in
      let bid = satoshis_of_string_exn r.bid in
      let ask = satoshis_of_string_exn r.ask in
      let last = satoshis_of_string_exn r.last_price in
      let low = satoshis_of_string_exn r.low in
      let high = satoshis_of_string_exn r.high in
      let volume = satoshis_of_string_exn r.volume in
      let ts = timestamp_of_string r.timestamp in
      new Mt.Ticker.Tvwap.t ~bid ~ask ~high ~low ~volume ~vwap ~last ~ts in
    ticker p >>| fun t -> R.map t of_raw

  module OrderBook = struct
    module T = struct
      type 'a book = {
        bids: 'a list;
        asks: 'a list;
      } [@@deriving yojson]

      type order = {
        price: string;
        amount: string;
        timestamp: string;
      } [@@deriving yojson]

      type t = order book [@@deriving yojson]
    end
    include T
    include Stringable.Of_jsonable(T)

    let book p = get ("/v1/book/" ^ string_of_symbol p) [] of_yojson
  end

  let book p =
    let open OrderBook in
    let of_raw { bids; asks; } =
      let of_raw r = new Tick.T.t
        ~p:(satoshis_of_string_exn r.price)
        ~v:(satoshis_of_string_exn r.amount) in
      List.map of_raw bids, List.map of_raw asks
    in
    book p >>| fun b -> R.map b of_raw

  module Trade = struct
    module T = struct
      type t = {
        timestamp: int;
        tid: int;
        price: string;
        amount: string;
        exchange: string;
        type_: string [@key "type"];
      } [@@deriving yojson]
    end
    include T
    include Stringable.Of_jsonable(T)

    let trades ?(since = -1L) ?(limit = -1) p =
      get ("/v1/trades/" ^ string_of_symbol p)
        ((if since = -1L then []
          else ["timestamp", Int64.(to_string @@ since / 1_000_000_000L)])
         @ (if limit = -1 then []
             else ["limit_trades", string_of_int limit]))
        ts_of_json

    let of_raw t =
      object
        method ts = Int64.(of_int t.timestamp * 1_000_000_000L + of_int t.tid)
        method p = satoshis_of_string_exn t.price
        method v = satoshis_of_string_exn t.amount
        method side = side_of_string t.type_
      end
  end

  let trades ?since ?limit p =
    let open Trade in
    trades ?since ?limit p >>| fun p ->
    R.map p (List.map of_raw)

  module Balance = struct
    module T = struct
      type t = {
        type_: string [@key "type"];
        currency: string;
        amount: string;
        available: string;
      } [@@deriving yojson]
    end
    include T
    include Stringable.Of_jsonable(T)

    let balance creds = post creds "/v1/balances" "" ts_of_json

    let of_raw t =
      if t.type_ = "trading" then
        let currency = CCOpt.get_exn @@ Currency.of_string t.currency in
        let balance = satoshis_of_string_exn t.amount in
        let available = satoshis_of_string_exn t.available in
        let reserved = Int64.(sub balance available) in
        Some
          (object
            method currency = currency
            method balance = balance
            method available = available
            method reserved = reserved
          end)
      else None
  end

  let balance creds =
    let open Balance in
    balance creds >>| fun b -> R.map b (CCList.filter_map of_raw)

  module Order = struct
    type request = {
      symbol: string;
      amount: string;
      price: string;
      exchange: string;
      side: string;
      type_: string [@key "type"];
      is_hidden: bool;
    } [@@deriving create,yojson]

    module Status = struct
      module T = struct
        type t = {
          id: int;
          order_id: (int [@default 0]);
          symbol: string;
          exchange: string;
          price: string;
          avg_execution_price: string;
          side: string;
          type_: string [@key "type"];
          timestamp: string;
          is_live: bool;
          is_cancelled: bool;
          is_hidden: bool;
          was_forced: bool;
          executed_amount: string;
          remaining_amount: string;
          original_amount: string;
        } [@@deriving create,yojson]
      end
      include T
      include Stringable.Of_jsonable(T)

      let of_raw s =
        let side = side_of_string s.side in
        let order_type, time_in_force = ot_tif_of_string s.type_ in
        object
          method exchange_order_id = string_of_int s.id
          method symbol = symbol_of_string_exn s.symbol
          method exchange = exchange_of_string_exn s.exchange
          method p1 = satoshis_of_string_exn s.price
          method p2 = 0L
          method order_qty = satoshis_of_string_exn s.original_amount
          method filled_qty = satoshis_of_string_exn s.executed_amount
          method avg_fill_price = satoshis_of_string_exn s.avg_execution_price
          method side = side
          method order_type = order_type
          method time_in_force = time_in_force
          method expire_ts = 0L
        end
    end

    let create_request ?(is_hidden=false)
        ~symbol ~amount ~price ~side ~order_type ~time_in_force () =
      let symbol = String.lowercase @@ string_of_symbol symbol in
      let amount = Format.sprintf "%.8f" @@ Int64.(to_float amount /. 1e8) in
      let price = Format.sprintf "%.8f" @@ Int64.(to_float price /. 1e8) in
      let exchange = "bitfinex" in
      let side = string_of_side side in
      let type_ = string_of_ot_tif order_type time_in_force in
      create_request ~symbol ~amount ~price ~exchange ~side ~type_ ~is_hidden ()
  end

  module Position = struct
    module T = struct
      type t = {
        id: int;
        symbol: string;
        status: string;
        base: string;
        amount: string;
        timestamp: string;
        swap: string;
        pl: string;
      } [@@deriving yojson]
    end
    include T
    include Stringable.Of_jsonable(T)

    let of_raw p =
      object
        method id = p.id
        method symbol = symbol_of_string_exn p.symbol
        method status = match p.status with "ACTIVE" -> `Active | _ -> `Unset
        method p = satoshis_of_string_exn p.base
        method v = satoshis_of_string_exn p.amount
        method ts = timestamp_of_string p.timestamp
        method swap = satoshis_of_string_exn p.swap
        method pl = satoshis_of_string_exn p.pl
      end
  end

  let positions creds =
    let open Position in
    post creds "/v1/positions" "" ts_of_json >>| fun positions ->
    R.map positions (List.map of_raw)

  let orders creds =
    let open Order.Status in
    post creds "/v1/orders" "" ts_of_json >>| fun statuses ->
    R.map statuses (List.map of_raw)

  module Filled_order = struct
    module T = struct
      type t = {
        tid: int64;
        order_id: int64;
        price: string;
        amount: string;
        timestamp: string;
        exchange: string;
        type_: string [@key "type"];
        fee_currency: string;
        fee_amount: string;
      } [@@deriving yojson]
    end
    include T
    include Stringable.Of_jsonable(T)

    let of_raw ~symbol t =
      object
        method tid = Int64.to_string t.tid
        method order_id = Int64.to_string t.order_id
        method symbol = symbol
        method p = satoshis_of_string_exn t.price
        method v = satoshis_of_string_exn t.amount
        method ts = timestamp_of_string t.timestamp
        method side = side_of_string @@ String.lowercase t.type_
        method fee_currency = Currency.of_string_exn t.fee_currency
        method fee_amount = satoshis_of_string_exn t.fee_amount
      end
  end

  let filled_orders ?(after=0L) ?(before=Int64.max_int) creds =
    let open Filled_order in
    let all_filled_orders =
      List.map
        (fun sym ->
           let open Yojson.Safe in
           post creds "/v1/mytrades"
             (to_string @@
              `Assoc ["symbol", `String (string_of_symbol sym);
                      "timestamp", `String Int64.(to_string @@ after / 1_000_000_000L);
                      "after", `String Int64.(to_string @@ before / 1_000_000_000L);
                     ]
             ) ts_of_json >>| fun filled -> sym, filled
        ) [`XBTUSD; (* `LTCUSD; `LTCXBT *)] in (* FIXME: workaround Bitfinex bad API call. *)
    all all_filled_orders >>| fun filled_orders ->
    R.ok @@
    CCList.(filter_map
      (function
        | symbol, Ok filled -> Some ((List.map (of_raw ~symbol)) filled)
        | _, Error _ -> None
      ) filled_orders |> flatten)

  let new_order creds order =
    let open Order in
    let order =
      create_request
        ~symbol:order#symbol
        ~price:order#price
        ~amount:order#amount
        ~side:order#side
        ~order_type:order#order_type
        ~time_in_force:order#time_in_force ()
    in
    let order_str = request_to_yojson order |> Yojson.Safe.to_string in
    let ret_of_json = function
      | `Assoc ["order_id", `Int i] -> R.ok i
      | json -> R.fail @@ `Json_error (Yojson.Safe.to_string json) in
    post creds "/v1/order/new" order_str ret_of_json

  let order_status creds order_id =
    let open Order.Status in
    post creds "/v1/order/status"
      Yojson.Safe.(to_string @@ `Assoc ["order_id", `Int order_id])
      of_yojson >>| fun status ->
    R.map status of_raw

  let cancel_order creds order_id =
    let open Order.Status in
    post creds "/v1/order/cancel"
      Yojson.Safe.(to_string @@ `Assoc ["order_id", `Int order_id])
      of_yojson >>| fun status ->
    R.map status (fun (_:t) -> ())
end

module Bitstamp (H: HTTP_CLIENT) = struct
  include H
  type symbol = [`XBTUSD]
  type exchange = [`Bitstamp]
  type ticker = (int64, int64) Ticker.Tvwap.t
  type book_entry = int64 Tick.T.t
  type trade = < p : int64; v : int64; side : [`Buy | `Sell]; ts : int64 >
  type nonrec credentials = credentials
  type order_types = [`Limit]
  type time_in_force = [`Good_till_canceled]
  type position
  type order
  type order_status
  type filled_order_status

  let kind = `Bitstamp
  let symbols = [`XBTUSD]

  let accept = function
    | `XBTUSD -> Some `XBTUSD
    | `LTCUSD -> None
    | `LTCXBT -> None
    | `XBTEUR -> None
    | `LTCEUR -> None
    | `XBTLTC -> None

  let price_increment = 1_000_000
  let trade_increment = 1

  let get endpoint params yojson_to_a =
    get endpoint params >>| fun s ->
    R.(s >>= yojson_of_string >>= yojson_to_a)

  let string_of_symbol = function
    | `XBTUSD -> "BTCUSD"

  module Ticker = struct
    module T = struct
      type t = {
        high: string;
        last: string;
        timestamp: string;
        bid: string;
        volume: string;
        vwap: string;
        low: string;
        ask: string;
      } [@@deriving yojson]
    end
    include T
    include Stringable.Of_jsonable(T)

    let ticker () = get "ticker/" [] of_yojson
  end

  let ticker _ =
    let open Ticker in
    let of_raw r =
      let vwap = satoshis_of_string_exn r.vwap in
      let bid = satoshis_of_string_exn r.bid in
      let ask = satoshis_of_string_exn r.ask in
      let last = satoshis_of_string_exn r.last in
      let low = satoshis_of_string_exn r.low in
      let high = satoshis_of_string_exn r.high in
      let volume = satoshis_of_string_exn r.volume in
      let ts = Int64.(of_string r.timestamp * 1_000_000_000L) in
      new Mt.Ticker.Tvwap.t ~bid ~ask ~high ~low ~volume ~vwap ~last ~ts
    in
    ticker () >>| fun t -> R.map t of_raw

  module OrderBook = struct
    module T = struct
      type t = {
        timestamp: string;
        bids: string list list;
        asks: string list list;
      } [@@deriving yojson]
    end

    include T
    include Stringable.Of_jsonable(T)

    let book () = get "order_book/" [] of_yojson
  end

  let book _ =
    let open OrderBook in
    let of_raw { bids; asks; _ } =
      let of_raw = function
        | [p; v] ->
          new Tick.T.t
            ~p:(satoshis_of_string_exn p)
            ~v:(satoshis_of_string_exn v)
        | _ -> invalid_arg "of_raw"
      in
      List.map of_raw bids, List.map of_raw asks
    in
    book () >>| fun b -> R.map b of_raw

  let trades ?since ?limit _ = return @@ R.fail `Not_implemented
  let balance _ = return @@ R.fail `Not_implemented
  let new_order _ _ = return @@ R.fail `Not_implemented
  let positions _ = return @@ R.fail `Not_implemented
  let orders _ = return @@ R.fail `Not_implemented
  let filled_orders ?after ?before creds = return @@ R.fail `Not_implemented
  let order_status _ _ = return @@ R.fail `Not_implemented
  let cancel_order _ _ = return @@ R.fail `Not_implemented
end

(* module Bittrex (H: HTTP_CLIENT) = struct *)
(*   open H *)

(*   type 'a error_monad = { *)
(*     success: bool; *)
(*     message: string; *)
(*     result: 'a option; *)
(*   } [@@deriving show,yojson] *)

(*   let get endpoint params yojson_to_a = *)
(*     let handle_err s = *)
(*       yojson_of_string s |> *)
(*       CCError.flat_map (error_monad_of_yojson yojson_to_a) |> *)
(*       CCError.flat_map *)
(*         (function | { success = true; result = Some r } -> `Ok r *)
(*                   | { success = false; message } -> `Error message *)
(*                   | _ -> `Error "success=true but result=None") *)
(*     in *)
(*     get endpoint params >>| CCError.flat_map handle_err *)

(*   type supported_curr = [`XBT | `LTC | `DOGE] *)

(*   let string_of_curr = function *)
(*     | `XBT -> "BTC" *)
(*     | `LTC -> "LTC" *)
(*     | `DOGE -> "DOGE" *)

(*   module Market = struct *)
(*     module Raw = struct *)
(*       module T = struct *)
(*         type t = { *)
(*           market_currency [@key "MarketCurrency"]: string; *)
(*           base_currency [@key "BaseCurrency"] : string; *)
(*           market_currency_long [@key "MarketCurrencyLong"] : string; *)
(*           base_currency_long [@key "BaseCurrencyLong"] : string; *)
(*           min_trade_size [@key "MinTradeSize"] : float; *)
(*           market_name [@key "MarketName"] : string; *)
(*           is_active [@key "IsActive"] : bool; *)
(*           created [@key "Created"] : string; *)
(*           notice [@key "Notice"] : string option; *)
(*           is_sponsored [@key "IsSponsored"] : bool option; *)
(*           logo_url [@key "LogoUrl"] : string option; *)
(*         } [@@deriving show,yojson] *)
(*       end *)

(*       include T *)
(*       include Stringable.Of_jsonable(T) *)

(*       let markets () = get "public/getmarkets" [] ts_of_json *)
(*     end *)
(*     include Raw *)
(*   end *)

(*   module MarketSummary = struct *)
(*     module Raw = struct *)
(*       module T = struct *)
(*         type t = { *)
(*           market_name [@key "MarketName"]: string; *)
(*           high [@key "High"]: float; *)
(*           low [@key "Low"]: float; *)
(*           volume [@key "Volume"]: float; *)
(*           last [@key "Last"]: float; *)
(*           base_volume [@key "BaseVolume"]: float; *)
(*           timestamp [@key "TimeStamp"]: string; *)
(*           bid [@key "Bid"]: float; *)
(*           ask [@key "Ask"]: float; *)
(*           open_buy_orders [@key "OpenBuyOrders"]: int; *)
(*           open_sell_orders [@key "OpenSellOrders"]: int; *)
(*           prev_day [@key "PrevDay"]: float; *)
(*           created [@key "Created"]: string; *)
(*         } [@@deriving show,yojson] *)
(*       end *)

(*       include T *)
(*       include Stringable.Of_jsonable(T) *)

(*       let summaries () = get "public/getmarketsummaries" [] ts_of_json *)
(*       let summary symbol = get "public/getmarketsummary" ["market", symbol] ts_of_json *)
(*     end *)
(*     include Raw *)
(*   end *)

(*   module Ticker = struct *)
(*     module Raw = struct *)
(*       type t = { *)
(*         bid [@key "Bid"] : float; *)
(*         ask [@key "Ask"] : float; *)
(*         last [@key "Last"] : float; *)
(*       } [@@deriving show,yojson] *)

(*       let ticker c1 c2 = get "public/getticker" *)
(*           ["market", string_of_curr c2 ^ "-" ^ string_of_curr c1] of_yojson *)
(*     end *)
(*     include Raw *)
(*   end *)

(*   module Currency = struct *)
(*     module T = struct *)
(*       type t = { *)
(*         currency [@key "Currency"] : string; *)
(*         currency_long [@key "CurrencyLong"] : string; *)
(*         min_confirmation [@key "MinConfirmation"] : int; *)
(*         tx_fee [@key "TxFee"] : float; *)
(*         is_active [@key "IsActive"] : bool; *)
(*         coin_type [@key "CoinType"] : string; *)
(*         base_addr [@key "BaseAddress"] : string option; *)
(*         notice [@key "Notice"] : string option; *)
(*       } [@@deriving show,yojson] *)
(*     end *)
(*     include T *)
(*     include Stringable.Of_jsonable(T) *)

(*     let currencies () = get "public/getcurrencies" [] ts_of_json *)
(*   end *)

(*   module OrderBook = struct *)
(*     type order = { *)
(*       price [@key "Rate"] : float; *)
(*       qty [@key "Quantity"] : float; *)
(*     } [@@deriving yojson] *)

(*     type book = { *)
(*       buy: order list; *)
(*       sell: order list *)
(*     } [@@deriving yojson] *)

(*     let book c1 c2 = get "public/getorderbook" *)
(*         ["market", string_of_curr c2 ^ "-" ^ string_of_curr c1; *)
(*          "type", "both"; "depth", "50"] book_of_yojson *)

(*     let of_raw t = *)
(*       Mt.OrderBook.create *)
(*         ~bids:(List.map (fun { price; qty; } -> *)
(*             let p = satoshis_of_float_exn price in *)
(*             let v = satoshis_of_float_exn qty in *)
(*             new Tick.t ~p ~v) t.buy) *)
(*         ~asks:(List.map (fun { price; qty; } -> *)
(*             let p = satoshis_of_float_exn price in *)
(*             let v = satoshis_of_float_exn qty in *)
(*             new Tick.t ~p ~v) t.sell) () *)
(*   end *)

(*   let book c1 c2 = OrderBook.(book c1 c2 >>| CCError.map of_raw) *)
(* end *)

(* module Cryptsy (H: HTTP_CLIENT) = struct *)
(*   open H *)

(*   type 'a error_monad = { *)
(*     success: bool; *)
(*     error: string [@default ""]; *)
(*     data: 'a option; *)
(*   } [@@deriving show,yojson] *)

(*   let get endpoint params yojson_to_a = *)
(*     let handle_err s = *)
(*       yojson_of_string s |> *)
(*       CCError.flat_map (error_monad_of_yojson yojson_to_a) |> *)
(*       CCError.flat_map *)
(*         (function | { success = true; data = Some r } -> `Ok r *)
(*                   | { success = false; error } -> `Error error *)
(*                   | _ -> `Error "success=true but data=None") *)
(*     in get endpoint params >>| CCError.flat_map handle_err *)

(*   type supported_curr = [`XBT | `LTC | `DOGE] *)

(*   module Currency = struct *)
(*     module Raw = struct *)
(*       module T = struct *)
(*         type t = { *)
(*           id: string; *)
(*           name: string; *)
(*           code: string; *)
(*           maintenance: string; *)
(*         } [@@deriving show,yojson] *)
(*       end *)
(*       include T *)
(*       include Stringable.Of_jsonable(T) *)

(*       let currencies () = get "currencies" [] ts_of_json *)
(*     end *)

(*     type t = { *)
(*       id: int; *)
(*       name: string; *)
(*       code: string; *)
(*       maintenance: int; *)
(*     } [@@deriving show,yojson] *)

(*     let of_raw r = { *)
(*       id = int_of_string r.Raw.id; *)
(*       name = r.Raw.name; *)
(*       code = r.Raw.code; *)
(*       maintenance = int_of_string r.Raw.maintenance; *)
(*     } *)

(*     let currencies () = Raw.currencies () >>| CCError.map @@ List.map of_raw *)
(*   end *)

(*   module Market = struct *)

(*     type stats = { *)
(*       volume: float; *)
(*       volume_btc: float; *)
(*       price_high: float; *)
(*       price_low: float; *)
(*     } [@@deriving show,yojson] *)

(*     type last_trade = { *)
(*       price: float; *)
(*       date: string; *)
(*       timestamp: int; *)
(*     } [@@deriving show,yojson] *)

(*     module Raw = struct *)
(*       module T = struct *)
(*         type t = { *)
(*           id: string; *)
(*           label: string; *)
(*           coin_currency_id: string; *)
(*           market_currency_id: string; *)
(*           maintenance_mode: string; *)
(*           verifiedonly: bool; *)
(*           stats [@key "24hr"] : stats; *)
(*           last_trade: last_trade; *)
(*         } [@@deriving show,yojson] *)
(*       end *)
(*       include T *)
(*       include Stringable.Of_jsonable(T) *)

(*       let markets () = get "markets" [] ts_of_json *)
(*     end *)

(*     type t = { *)
(*       id: int; *)
(*       label: string; *)
(*       coin_currency_id: int; *)
(*       market_currency_id: int; *)
(*       maintenance_mode: int; *)
(*       verifiedonly: bool; *)
(*       stats : stats; *)
(*       last_trade: last_trade; *)
(*     } [@@deriving show,yojson] *)

(*     let of_raw t = { *)
(*       id = int_of_string t.Raw.id; *)
(*       label = t.Raw.label; *)
(*       coin_currency_id = int_of_string t.Raw.coin_currency_id; *)
(*       market_currency_id = int_of_string t.Raw.market_currency_id; *)
(*       maintenance_mode = int_of_string t.Raw.maintenance_mode; *)
(*       verifiedonly = t.Raw.verifiedonly; *)
(*       stats = t.Raw.stats; *)
(*       last_trade = t.Raw.last_trade; *)
(*     } *)

(*     let markets () = Raw.markets () >>| CCError.map @@ List.map of_raw *)
(*   end *)

(*   module Ticker = struct *)
(*     module Raw = struct *)
(*       module T = struct *)
(*         type t = { *)
(*           id: string; *)
(*           bid: float; *)
(*           ask: float; *)
(*         } [@@deriving show,yojson] *)
(*       end *)
(*       include T *)
(*       include Stringable.Of_jsonable(T) *)

(*       let string_of_curr = function *)
(*         | `XBT -> "btc" *)
(*         | `LTC -> "ltc" *)
(*         | `DOGE -> "doge" *)

(*       let ticker c1 c2 = get *)
(*           ("markets/" ^ string_of_curr c1 ^ "_" ^ string_of_curr c2 ^ "/ticker") *)
(*           [] of_yojson *)

(*       let tickers () = get "markets/ticker" [] ts_of_json *)
(*     end *)

(*     type t = { *)
(*       id: int; *)
(*       bid: float; *)
(*       ask: float; *)
(*     } [@@deriving show,yojson] *)

(*     let of_raw t = { *)
(*       id = int_of_string t.Raw.id; *)
(*       bid = t.Raw.bid; *)
(*       ask = t.Raw.ask; *)
(*     } *)

(*     let ticker c1 c2 = Raw.ticker c1 c2 >>| CCError.map of_raw *)
(*     let tickers () = Raw.tickers () >>| CCError.map @@ List.map of_raw *)
(*   end *)
(* end *)

module BTCE (H: HTTP_CLIENT) = struct
  include H
  type symbol = [`XBTUSD | `LTCUSD | `XBTEUR | `LTCEUR | `LTCXBT]
  type exchange = [`BTCE]
  type ticker = (int64, int64) Ticker.Tvwap.t
  type book_entry = int64 Tick.T.t
  type trade = < p : int64; v : int64; side : [`Buy | `Sell]; ts : int64 >
  type nonrec credentials = credentials
  type position
  type order
  type order_status
  type filled_order_status

  let kind = `BTCE

  let symbols = [`XBTUSD; `LTCUSD; `XBTEUR; `LTCEUR; `LTCXBT]

  let price_increment = 100_000
  let trade_increment = 1

  let accept = function
    | `XBTUSD -> Some `XBTUSD
    | `LTCUSD -> Some `LTCUSD
    | `LTCXBT -> Some `LTCXBT
    | `XBTEUR -> Some `XBTEUR
    | `LTCEUR -> Some `LTCEUR
    | `XBTLTC -> None

  let string_of_symbol = function
    | `XBTUSD -> "btc_usd"
    | `LTCUSD -> "ltc_usd"
    | `XBTEUR -> "btc_eur"
    | `LTCEUR -> "ltc_eur"
    | `LTCXBT -> "ltc_btc"

  let get endpoint params yojson_to_a =
    let handle_err s =
      R.(yojson_of_string s >>= function
        | `Assoc [(_, ret)] -> yojson_to_a ret
        | _ -> Error (`Json_error s)
        )
    in
    get endpoint params >>| fun s -> R.(s >>= handle_err)

  module Ticker = struct
    module T = struct
      type t = {
        high: float;
        low: float;
        avg: float;
        vol: float;
        vol_cur: float;
        last: float;
        buy: float;
        sell: float;
        updated: int;
      } [@@deriving yojson]
    end
    include T
    include Stringable.Of_jsonable(T)

    let ticker p = get ("ticker/" ^ string_of_symbol p) [] of_yojson

    let of_raw t =
      new Ticker.Tvwap.t
        ~bid:(satoshis_of_float_exn t.buy)
        ~ask:(satoshis_of_float_exn t.sell)
        ~last:(satoshis_of_float_exn t.last)
        ~high:(satoshis_of_float_exn t.high)
        ~low:(satoshis_of_float_exn t.low)
        ~vwap:(satoshis_of_float_exn t.avg)
        ~volume:(satoshis_of_float_exn t.vol)
        ~ts:Int64.(of_int t.updated * 1_000_000_000L)
  end
  let ticker p =
    Ticker.(ticker p >>| fun t -> R.map t of_raw)

  module OrderBook = struct
    module T = struct
      type t = {
        asks: float list list;
        bids: float list list
      } [@@deriving yojson]
    end
    include T
    include Stringable.Of_jsonable(T)
  end

  let book p =
    let open OrderBook in
    get ("depth/" ^ string_of_symbol p) [] of_yojson >>|
      (fun t ->
         let f t =
           List.map (function
                | [p; v] ->
                  new Tick.T.t
                    ~p:(satoshis_of_float_exn p)
                    ~v:(satoshis_of_float_exn v)
                | _ -> raise Exit)
             t.bids,
           List.map (function
                | [p; v] ->
                  new Tick.T.t
                    ~p:(satoshis_of_float_exn p)
                    ~v:(satoshis_of_float_exn v)
                | _ -> raise Exit)
             t.asks
         in
         try R.(t >>| f)
         with Exit -> R.error @@ `Json_error "book"
      )

  module Trade = struct
    module T = struct
      type t = {
        type_: string [@key "type"];
        price: float;
        amount: float;
        tid: int;
        timestamp: int;
      } [@@deriving yojson]
    end
    include T
    include Stringable.Of_jsonable(T)

    let trades p = get ("trades/" ^ string_of_symbol p) [] ts_of_json
  end

  let trades ?since ?limit p =
    let open Trade in
    trades p >>| fun trades ->
    R.(trades >>|
       List.map (fun t ->
           object
             method ts = Int64.(of_int t.timestamp * 1_000_000_000L + of_int t.tid)
             method p = satoshis_of_float_exn t.price
             method v = satoshis_of_float_exn t.amount
             method side = match t.type_ with "bid" -> `Buy | _ -> `Sell
           end
         )
      )

  let balance _ = return @@ R.fail `Not_implemented
  let new_order _ _ = return @@ R.fail `Not_implemented
  let positions _ = return @@ R.fail `Not_implemented
  let orders _ = return @@ R.fail `Not_implemented
  let filled_orders ?after ?before creds = return @@ R.fail `Not_implemented
  let order_status _ _ = return @@ R.fail `Not_implemented
  let cancel_order _ _ = return @@ R.fail `Not_implemented
end

(* module Poloniex (H: HTTP_CLIENT) = struct *)
(*   open H *)

(*   type supported_curr = [`XBT | `LTC | `DOGE] *)

(*   let string_of_curr = function *)
(*     | `XBT -> "BTC" *)
(*     | `LTC -> "LTC" *)
(*     | `DOGE -> "DOGE" *)

(*   module Ticker = struct *)
(*     let get c1 c2 params yojson_to_a = *)
(*       let handle_err s = *)
(*         let curr_str = string_of_curr c2 ^ "_" ^ string_of_curr c1 in *)
(*         yojson_of_string s |> CCError.flat_map *)
(*           (function *)
(*             | `Assoc l -> *)
(*               (try *)
(*                  let t = List.assoc curr_str l in yojson_to_a t *)
(*                with Not_found -> `Error "Unknown currency") *)
(*             | _ -> `Error s) *)
(*       in *)
(*       get "" params >>| CCError.flat_map handle_err *)

(*     module Raw = struct *)
(*       module T = struct *)
(*         type t = { *)
(*           last: string; *)
(*           lowestAsk: string; *)
(*           highestBid: string; *)
(*           percentChange: string; *)
(*           baseVolume: string; *)
(*           quoteVolume: string; *)
(*           isFrozen: string; *)
(*           high24hr: string; *)
(*           low24hr: string; *)
(*         } [@@deriving show,yojson] *)
(*       end *)
(*       include T *)
(*       include Stringable.Of_jsonable(T) *)

(*       let ticker c1 c2 = get c1 c2 ["command", "returnTicker"] of_yojson *)
(*     end *)

(*     let of_raw t = new Mt.Ticker.t *)
(*       ~ts:(Unix.gettimeofday () *. 1e9 |> Int64.of_float) *)
(*       ~last:(satoshis_of_string_exn t.Raw.last) *)
(*       ~bid:(satoshis_of_string_exn t.Raw.highestBid) *)
(*       ~ask:(satoshis_of_string_exn t.Raw.lowestAsk) *)
(*       ~volume:(satoshis_of_string_exn t.Raw.baseVolume) *)
(*       ~high:(satoshis_of_string_exn t.Raw.high24hr) *)
(*       ~low:(satoshis_of_string_exn t.Raw.low24hr) *)

(*     let ticker c1 c2 = Raw.ticker c1 c2 >>| CCError.map of_raw *)
(*   end *)

(*   module OrderBook = struct *)
(*     let book c1 c2 = *)
(*       let curr_str = string_of_curr c2 ^ "_" ^ string_of_curr c1 in *)

(*       let handle_err s = *)
(*         let parse = *)
(*           let mapf = function *)
(*             | `List [`String p; `Float v] -> *)
(*               new Tick.t *)
(*                 ~p:(satoshis_of_string_exn p) *)
(*                 ~v:(satoshis_of_float_exn v) *)
(*             | `List [`String p; `Int v] -> *)
(*               new Tick.t *)
(*                 ~p:(satoshis_of_string_exn p) *)
(*                 ~v:Int64.(10_000_000L * of_int v) *)
(*             | json -> invalid_arg @@ Yojson.Safe.to_string json in *)
(*           List.map mapf in *)
(*         yojson_of_string s |> CCError.flat_map *)
(*           (function *)
(*             | `Assoc ["asks", `List asks; "bids", `List bids; "isFrozen", `String frz] -> *)
(*               if frz <> "0" *)
(*               then `Ok (Mt.OrderBook.create ()) *)
(*               else *)
(*                 let f () = Mt.OrderBook.create ~asks:(parse asks) ~bids:(parse bids) () *)
(*                 in *)
(*                 (try `Ok (f ()) with Invalid_argument str -> `Error str) *)
(*             | json -> `Error (Yojson.Safe.to_string json)) *)
(*       in *)
(*       get "" ["command", "returnOrderBook"; *)
(*               "currencyPair", curr_str] >>| CCError.flat_map handle_err *)
(*   end *)
(* end *)

module Kraken (H: HTTP_CLIENT) = struct
  include H
  type symbol = [`XBTUSD | `LTCUSD | `XBTEUR | `LTCEUR | `XBTLTC]
  type exchange = [`Kraken]
  type ticker = (int64, int64) Ticker.Tvwap.t
  type trade =
    < p : int64; v : int64; side : [`Buy | `Sell]; ts : int64;
      order_type : [`Market | `Limit | `Unset]; misc : string;
    >
  type book_entry = (int64, int64) Tick.TTS.t
  type nonrec credentials = credentials
  type order_types = [`Market | `Limit]
  type time_in_force = [`Good_till_canceled]
  type position
  type order
  type filled_order_status =
    < fee_amount : int64; fee_currency : Mt.Currency.t;
      order_id : string; p : int64; side : [ `Buy | `Sell ];
      symbol : symbol; tid : string; ts : int64; v : int64 >
  type order_status =
    < avg_fill_price : int64;
      exchange : Exchange.t;
      exchange_order_id : string;
      expire_ts : int64;
      filled_qty : int64;
      order_qty : int64;
      order_type : [ `Limit | `Market
                   | `Market_if_touched | `Stop | `Stop_limit ];
      p1 : int64;
      p2 : int64;
      side : [ `Buy | `Sell ];
      symbol : Symbol.t;
      time_in_force : [ `Good_till_canceled | `Good_till_date_time ]
    >

  let kind = `Kraken
  let symbols = [`XBTUSD; `LTCUSD; `XBTEUR; `LTCEUR; `XBTLTC]

  let price_increment = 1_000
  let trade_increment = 1

  let accept = function
    | `XBTLTC -> Some `XBTLTC
    | `XBTUSD -> Some `XBTUSD
    | `LTCUSD -> Some `LTCUSD
    | `XBTEUR -> Some `XBTEUR
    | `LTCEUR -> Some `LTCEUR
    | `LTCXBT -> None

  let string_of_symbol = function
    | `XBTUSD -> "XXBTZUSD"
    | `LTCUSD -> "XLTCZUSD"
    | `XBTEUR -> "XXBTZEUR"
    | `LTCEUR -> "XLTCZEUR"
    | `XBTLTC -> "XXBTXLTC"

  let symbol_of_string_exn = function
    | "XBTEUR" -> `XBTEUR
    | "XXBTZEUR" -> `XBTEUR
    | "XBTUSD" -> `XBTUSD
    | "XXBTZUSD" -> `XBTUSD
    | _ -> invalid_arg "symbol_of_string_short_exn"

  let ordertype_of_string_exn = function
    | "market" -> `Market
    | "limit" -> `Limit
    | "stop-loss" -> `Stop
    | "stop-loss-limit" -> `Stop_limit
    | "take-profit" -> `Market_if_touched
    | _ -> invalid_arg "ordertype_of_string_exn"

  type 'a error_monad = {
    error: string list;
    result: ('a option [@default None]);
  } [@@deriving yojson]

  let error_of_error_monad e =
    match e.result with
    | None -> exchange_error @@ String.concat " " e.error
    | Some res -> R.ok res

  let get endpoint params yojson_to_a =
    let handle_err s =
      let open R in
      yojson_of_string s >>=
      (fun json -> R.(reword_error (fun str -> `Json_error str)
                      @@ of_presult (error_monad_of_yojson yojson_to_a json))) >>=
      error_of_error_monad
    in
    get endpoint params >>| fun s -> R.(s >>= handle_err)

  let post credentials endpoint params yojson_to_a =
    let handle_err s =
      let open R in
      yojson_of_string s >>=
      (fun json -> R.(reword_error (fun str -> `Json_error str)
                      @@ of_presult (error_monad_of_yojson yojson_to_a json))) >>=
      error_of_error_monad
    in
    let body = Uri.encoded_of_query @@
      List.map (fun (a, b) -> a, [b]) params in
    post credentials endpoint body >>| fun s -> R.(s >>= handle_err)

  module Ticker = struct
    type t = {
      a: string list;
      b: string list;
      c: string list;
      v: string list;
      p: string list;
      t: int list;
      l: string list;
      h: string list;
      o: string;
    } [@@deriving yojson]

    let ticker p = get "/0/public/Ticker" ["pair", string_of_symbol p]
        (function | `Assoc [_, t] -> of_yojson t
                  | json -> `Error (Yojson.Safe.to_string json))

    let of_raw t = new Mt.Ticker.Tvwap.t
      ~ts:(Unix.gettimeofday () *. 1e9 |> Int64.of_float)
      ~bid:(satoshis_of_string_exn @@ List.hd t.b)
      ~ask:(satoshis_of_string_exn @@ List.hd t.a)
      ~last:(satoshis_of_string_exn @@ List.hd t.c)
      ~volume:(satoshis_of_string_exn @@ List.nth t.v 1)
      ~vwap:(satoshis_of_string_exn @@ List.nth t.p 1)
      ~low:(satoshis_of_string_exn @@ List.nth t.l 1)
      ~high:(satoshis_of_string_exn @@ List.nth t.h 1)
  end

  let ticker p = Ticker.(ticker p >>| fun t -> R.map t of_raw)

  let book p =
    let lift_f = function
      | `Assoc ["asks", `List asks; "bids", `List bids] ->
        let book_of_json json = List.map (function
            | `List [`String p; `String v; `Int ts] ->
              new Tick.TTS.t
                ~p:(satoshis_of_string_exn p)
                ~v:(satoshis_of_string_exn v)
                ~ts:Int64.(1_000_000L * of_int ts)
            | _ -> raise Exit
          ) json in
        (try `Ok (book_of_json bids, book_of_json asks) with Exit -> `Error "book")
      | json -> `Error (Yojson.Safe.to_string json) in

    get "/0/public/Depth" ["pair", string_of_symbol p]
      (function | `Assoc [_, t] -> lift_f t
                | json -> `Error (Yojson.Safe.to_string json))

  let ts_of_float ts =
    let ns_of_float ts =
      let s = Printf.sprintf "%.9f" ts in
      Int64.of_string @@ String.(sub s (index s '.' + 1) 9) in
    Int64.(of_int (truncate ts) * 1_000_000_000L + ns_of_float ts)

  let trades ?(since = -1L) ?(limit = -1) p =
    let trade_of_json = function
      | `List [`String p; `String v; `Int ts; `String d; `String k; `String m] ->
        `Ok (object
          method ts = Int64.(of_int ts * 1_000_000_000L)
          method p = satoshis_of_string_exn p
          method v = satoshis_of_string_exn v
          method side = match d with "b" -> `Buy | _ -> `Sell
          method order_type = match k with "l" -> `Limit | "m" -> `Market | _ -> `Unset
          method misc = m
        end)
      | `List [`String p; `String v; `Float ts; `String d; `String k; `String m] ->
        `Ok (object
          method ts = ts_of_float ts
          method p = satoshis_of_string_exn p
          method v = satoshis_of_string_exn v
          method side = match d with "b" -> `Buy | _ -> `Sell
          method order_type = match k with "l" -> `Limit | "m" -> `Market | _ -> `Unset
          method misc = m
        end)
      | json -> `Error (Yojson.Safe.to_string json) in
    get "/0/public/Trades" (("pair", string_of_symbol p) ::
    (if since = -1L then [] else ["since", Int64.to_string since]))
      (function | `Assoc [_, `List trades; _] -> CCError.map_l trade_of_json trades
                | json -> `Error (Yojson.Safe.to_string json))

  module Balance = struct
    type t = {
      eb: string;
      tb: string;
      m: string;
      n: string;
      c: string;
      v: string;
      e: string;
      mf: string;
      ml: (string [@default ""]);
    } [@@deriving yojson]

    let of_raw t =
      object
        method currency = `USD
        method balance = satoshis_of_string_exn t.tb
        method available = satoshis_of_string_exn t.mf
        method reserved = satoshis_of_string_exn t.m
      end
  end

  let balance creds =
    let open Balance in
    post creds "/0/private/TradeBalance" [] of_yojson >>| fun balance ->
    R.map balance (fun b -> [of_raw b])

  let positions creds =
    post creds "/0/private/OpenPositions" [] (fun json -> `Error "not impl")

  module Order = struct
    type descr = {
      pair: string;
      type_: string [@key "type"];
      ordertype: string;
      price: string;
      price2: string;
      leverage: string;
      order: string;
      close: (string [@default ""]);
    } [@@deriving yojson]

    type t = {
      refid: string option;
      userref: string option;
      status: string;
      opentm: float;
      starttm: float;
      expiretm: float;
      descr: descr;
      vol: string;
      vol_exec: string;
      cost: string;
      fee: string;
      price: string;
      stopprice: (string [@default ""]);
      limitprice: (string [@default ""]);
      misc: string;
      oflags: string;
      trades: (string list [@default []]);
    } [@@deriving yojson]

    let of_raw (txid, json) =
      CCError.map
        (fun t ->
           object
             method exchange_order_id = txid
             method symbol = symbol_of_string_exn t.descr.pair
             method exchange = `Kraken
             method p1 = satoshis_of_string_exn t.descr.price
             method p2 = satoshis_of_string_exn t.descr.price2
             method order_qty = satoshis_of_string_exn t.vol
             method filled_qty = satoshis_of_string_exn t.vol_exec
             method avg_fill_price = satoshis_of_string_exn t.price
             method side = match t.descr.type_ with "buy" -> `Buy | _ -> `Sell
             method order_type = ordertype_of_string_exn t.descr.ordertype
             method time_in_force = match t.expiretm with
               | 0. -> `Good_till_canceled
               | _ -> `Good_till_date_time
             method expire_ts = Int64.of_float @@ t.expiretm *. 1e9
           end) (of_yojson json) |> CCError.to_opt
  end

  let orders creds =
    let open Order in
    post creds "/0/private/OpenOrders" []
      (function
        | `Assoc ["open", `Assoc orders] ->
          `Ok (CCList.filter_map of_raw orders)
        | json ->
          `Error Yojson.Safe.(to_string json)
      )

  module Filled_order = struct
    type t = {
      ordertxid: string;
      pair: string;
      time: float;
      type_: string [@key "type"];
      ordertype: string;
      price: string;
      cost: string;
      fee: string;
      vol: string;
      margin: string;
      misc: string;
      closing: (bool [@default false]);
      posstatus: (string [@default ""]);
      cprice: (string [@default ""]);
      ccost: (string [@default ""]);
      cfee: (string [@default ""]);
      cvol: (string [@default ""]);
      cmargin: (string [@default ""]);
      net: (string [@default ""]);
      trades: (string list [@default []]);
    } [@@deriving yojson]

    let of_raw (txid, json) =
      CCError.map
        (fun t -> object
          method tid = txid
          method order_id = t.ordertxid
          method p = satoshis_of_string_exn t.price
          method v = satoshis_of_string_exn t.vol
          method side = match t.type_ with "buy" -> `Buy | _ -> `Sell
          method symbol = symbol_of_string_exn t.pair
          method ts = ts_of_float t.time
        end) (of_yojson json) |> CCError.to_opt
  end

  let filled_orders ?(after=0L) ?(before=Int64.max_int) creds =
    let open Filled_order in
    post creds "/0/private/TradesHistory"
      ["start", Int64.(to_string @@ after / 1_000_000_000L);
       "end", Int64.(to_string @@ before / 1_000_000_000L);
      ]
      (function
        | `Assoc ["trades", `Assoc trades; "count", _] ->
          `Ok (CCList.filter_map of_raw trades)
        | json ->
          `Error (Yojson.Safe.to_string json)
      )

  let new_order _ _ = return @@ R.fail `Not_implemented
  let order_status _ _ = return @@ R.fail `Not_implemented
  let cancel_order _ _ = return @@ R.fail `Not_implemented
end

(* module Hitbtc (H: HTTP_CLIENT) = struct *)
(*   open H *)

(*   let get endpoint params yojson_to_a = *)
(*     let handle_err s = *)
(*       CCError.flat_map yojson_to_a @@ yojson_of_string s in *)
(*     get endpoint params >>| CCError.flat_map handle_err *)

(*   type supported_curr = [`XBT | `LTC | `DOGE] *)

(*   let string_of_curr = function *)
(*     | `XBT -> "BTC" *)
(*     | `LTC -> "LTC" *)
(*     | `DOGE -> "DOGE" *)

(*   module Ticker = struct *)
(*     module Raw = struct *)
(*       type t = { *)
(*         ask: string; *)
(*         bid: string; *)
(*         last: string; *)
(*         low: string; *)
(*         high: string; *)
(*         o [@key "open"]: string; *)
(*         volume: string; *)
(*         volume_quote: string; *)
(*         timestamp: int; *)
(*       } [@@deriving yojson] *)

(*       let ticker c1 c2 = *)
(*         get ("public/" ^ string_of_curr c1 ^ string_of_curr c2 ^ "/ticker") [] *)
(*           of_yojson *)
(*     end *)

(*     let of_raw t = new Mt.Ticker.t *)
(*       ~ask:(satoshis_of_string_exn t.Raw.ask) *)
(*       ~bid:(satoshis_of_string_exn t.Raw.bid) *)
(*       ~last:(satoshis_of_string_exn t.Raw.last) *)
(*       ~low:(satoshis_of_string_exn t.Raw.low) *)
(*       ~high:(satoshis_of_string_exn t.Raw.high) *)
(*       ~volume:(satoshis_of_string_exn t.Raw.volume) *)
(*       ~ts:Int64.(1000L * of_int t.Raw.timestamp) *)

(*     let ticker c1 c2 = Raw.ticker c1 c2 >>| CCError.map of_raw *)
(*   end *)

(*   module OrderBook = struct *)
(*     module Raw = struct *)

(*       type t = { *)
(*         asks: string list list; *)
(*         bids: string list list; *)
(*       } [@@deriving yojson] *)

(*       let book c1 c2 = *)
(*         get ("public/" ^ string_of_curr c1 ^ string_of_curr c2 ^ "/orderbook") [] *)
(*           of_yojson *)
(*     end *)

(*     let of_raw t = *)
(*       let f t = *)
(*        Mt.OrderBook.create *)
(*           ~bids:(List.map (function *)
(*               | [p; v] -> *)
(*                 new Tick.t *)
(*                   ~p:(satoshis_of_string_exn p) *)
(*                   ~v:(satoshis_of_string_exn v) *)
(*               | _ -> raise Exit *)
(*             ) t.Raw.bids) *)
(*           ~asks:(List.map (function *)
(*               | [p; v] -> *)
(*                 new Tick.t *)
(*                   ~p:(satoshis_of_string_exn p) *)
(*                   ~v:(satoshis_of_string_exn v) *)
(*               | _ -> raise Exit *)
(*             ) t.Raw.asks) () *)
(*       in try `Ok (f t) with Exit -> `Error "of_raw" *)

(*     let book c1 c2 = Raw.book c1 c2 >>| CCError.map of_raw *)
(*   end *)
(* end *)
