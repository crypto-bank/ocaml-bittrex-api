module type HTTP_CLIENT = sig
  include Cohttp.S.IO

  val get : string -> (string * string) list -> string t
end

module OrderBook : sig
  type 'a book = {
    bids: 'a list;
    asks: 'a list;
  } [@@deriving show,yojson]

  type order = {
    price: float;
    qty: float;
  } [@@deriving show,yojson,create]

  type t = order book [@@deriving show,yojson]
end

module Ticker : sig
  type t = {
    last: float;
    bid: float;
    ask: float;
    high: float;
    low: float;
    volume: float;
    timestamp: float;
    vwap: float option;
  } [@@deriving show,create]
end

module Trade : sig
  type kind = [`Ask | `Bid | `Unknown] [@@deriving show]

  type t = {
    ts: float;
    price: float;
    qty: float;
    kind: kind;
  } [@@deriving show,create]
end

module type EXCHANGE = sig
  type 'a io
  type currency

  module Ticker : sig
    val ticker : currency -> currency -> (Ticker.t, string) CCError.t io
  end

  module OrderBook : sig
    val book : currency -> currency -> (OrderBook.t, string) CCError.t io
  end

  module Trade : sig
    val trades : ?since:float -> ?limit:int ->
      currency -> currency -> (Trade.t list, string) CCError.t io
  end
end

module Bitfinex (H: HTTP_CLIENT) :
  EXCHANGE with type currency = [`BTC | `LTC | `USD]
            and type 'a io := 'a H.t

module BTCE (H: HTTP_CLIENT) :
  EXCHANGE with type currency = [`BTC | `LTC]
            and type 'a io = 'a H.t

module Bittrex (H: HTTP_CLIENT) : sig
  type supported_curr = [`BTC | `LTC | `DOGE]

  module Market : sig
    type t = {
      market_currency: string;
      base_currency: string;
      market_currency_long: string;
      base_currency_long: string;
      min_trade_size: float;
      market_name: string;
      is_active: bool;
      created: string;
      notice: string option;
      is_sponsored: bool option;
      logo_url: string option;
    } [@@deriving show,yojson]

    val markets : unit -> t list H.t
  end

  module MarketSummary : sig
    type t = {
      market_name: string;
      high: float;
      low: float;
      volume: float;
      last: float;
      base_volume: float;
      timestamp: string;
      bid: float;
      ask: float;
      open_buy_orders: int;
      open_sell_orders: int;
      prev_day: float;
      created: string;
    } [@@deriving show,yojson]

    val summaries : unit -> t list H.t
    val summary : string -> t list H.t
  end

  module Ticker : sig
    type t = {
      bid: float;
      ask: float;
      last: float;
    } [@@deriving show,yojson]

    val ticker : supported_curr -> supported_curr -> t H.t
    (** [ticker currency_pair] returns the ticker for the given
        [currency_pair]. *)
  end

  module Currency : sig
    type t = {
      currency: string;
      currency_long: string;
      min_confirmation: int;
      tx_fee: float;
      is_active: bool;
      coin_type: string;
      base_addr: string option;
      notice: string option;
    } [@@deriving show,yojson]

    val currencies : unit -> t list H.t
  end

  module OrderBook : sig
    val book : supported_curr -> supported_curr -> OrderBook.t H.t
  end
end

module Cryptsy (H: HTTP_CLIENT) : sig
  type supported_curr = [`BTC | `LTC | `DOGE]

  module Currency : sig
    type t = {
      id: int;
      name: string;
      code: string;
      maintenance: int;
    } [@@deriving show,yojson]

    val currencies : unit -> t list H.t
  end

  module Market : sig
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

    val markets : unit -> t list H.t
  end

  module Ticker : sig
    type t = {
      id: int;
      bid: float;
      ask: float;
    } [@@deriving show,yojson]

    val ticker : supported_curr -> supported_curr -> t H.t
    val tickers : unit -> t list H.t
  end
end


module Poloniex (H: HTTP_CLIENT) : sig
  type supported_curr = [`BTC | `LTC | `DOGE]

  module Ticker : sig
    type t = {
      last: float;
      bid: float;
      ask: float;
      percent_change: float;
      base_volume: float;
      quote_volume: float;
      is_frozen: bool;
      high: float;
      low: float;
    } [@@deriving show]

    val ticker : supported_curr -> supported_curr -> t H.t
  end

  module OrderBook : sig
    val book : supported_curr -> supported_curr -> OrderBook.t H.t
  end
end

module Kraken (H: HTTP_CLIENT) : sig
  type supported_curr = [`BTC | `LTC | `DOGE]

  module Ticker : sig
    type t = {
      bid: float;
      ask: float;
      vol: float;
      vwap: float;
      nb_trades: int;
      low: float;
      high: float;
    } [@@deriving show]

    val ticker : supported_curr -> supported_curr -> t H.t
  end

  module OrderBook : sig
    val book : supported_curr -> supported_curr -> OrderBook.t H.t
  end
end

module Hitbtc (H: HTTP_CLIENT) : sig
  type supported_curr = [`BTC | `LTC | `DOGE]

  module Ticker : sig
    type t = {
      ask: float;
      bid: float;
      last: float;
      low: float;
      high: float;
      o: float;
      volume: float;
      volume_quote: float;
      timestamp: int;
    } [@@deriving show]

    val ticker : supported_curr -> supported_curr -> t H.t
  end

  module OrderBook : sig
    val book : supported_curr -> supported_curr -> OrderBook.t H.t
  end
end
