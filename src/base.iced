status_enum           = require './status'
sc                    = status_enum.codes
sc_lookup             = status_enum.lookup
log                   = require './log'
mm                    = require('./mod').mgr
url                   = require 'url'
env                   = require './env'
{json_checker}        = require './json_checker'
{respond}             = require 'keybase-bjson-express'
core                  = require 'keybase-bjson-core'
{chain,make_esc}      = require 'iced-error'

util = require 'util'

##-----------------------------------------------------------------------

make_status_obj = (code, desc, fields) ->
  out = { code }
  out.desc = desc if desc?
  out.fields = fields if fields?
  out.name = sc_lookup[code]
  return out
  
##-----------------------------------------------------------------------

exports.Handler = class Handler

  constructor : (@req, @res) ->
    log.make_logs @,  { remote : @req.ip, prefix : @req.protocol }
    @_error_in_field    = {}
    @oo                 = { status : {}, body : {} }
    @user               = null
    @response_sent_yet  = false
    @http_out_code      = 200
    @out_encoding       = 'json'
   
  #-----------------------------------------

  input_template : -> {}

  #-----------------------------------------

  is_input_ok : () -> Object.keys(@_error_in_field).length is 0
   
  #-----------------------------------------

  allow_cross_site_get_requests : () -> false

  #-----------------------------------------

  pub : (dict) -> @oo.body[k] = v for k,v of dict
  clear_pub : () -> @oo = { status : {}, body : {}}

  #-----------------------------------------

  set_error : (code, desc = null, fields = null) ->
    @oo.status = make_status_obj code, desc, fields

  #-----------------------------------------

  set_ok : () -> @set_error sc.OK
   
  #-----------------------------------------

  is_ok : () -> 
    (not @oo?.status?.code?) or (@oo.status.code is sc.OK)

  #-----------------------------------------

  status_code : () -> @oo?.status?.code or sc.OK
  status_name : () -> 
    code = @status_code()
    sc_lookup[code] or "code-#{code}"
  handler_name : () -> @constructor.name

  #-----------------------------------------

  get_iparam : (f) -> parseInt(@req.param(f), 10)
  
  #-----------------------------------------
  
  send_res_json : (cb) ->
    respond { obj : @oo, code : @http_out_code, encoding : @out_encoding, @res }
    @response_sent_yet = true
    cb()

  #==============================================
  
  handle : (cb) ->
    await @__handle_stage_1 defer e1       # input & header processing
    await @__handle_stage_2 e1, defer e2   # custom logic OR error handling
    await @__handle_stage_3 e2, defer()    # output 
    cb()

  #------

  __handle_stage_1 : (cb) ->
    esc = make_esc cb, "Handler::handle"
    await @__handle_universal_headers esc defer()
    await @__set_cross_site_get_headers esc defer()
    await @__handle_input esc defer()
    await @_handle_auth esc defer()
    cb()

  #------

  _handle_auth : (cb) -> cb null

  #------

  __set_cross_site_get_headers: (cb) ->
    if @allow_cross_site_get_requests()
      @res.set 'Access-Control-Allow-Origin' :     '*'
      @res.set 'Access-Control-Allow-Methods':     'GET'
      @res.set 'Access-Control-Allow-Headers':     'Content-Type, Authorization, Content-Length, X-Requested-With'
      # I believe this is the default anyway, but let's play it safe
      @res.set 'Access-Control-Allow-Credentials': 'false'
    cb()

  #------

  __handle_universal_headers : (cb) ->
    if env.get().get_run_mode().is_prod()
      @res.set "Strict-Transport-Security", "max-age=31536000"
    cb()

  #------

  __check_inputs : () ->
    err = core.check_template @input_template(), @input, "HTTP"
    if err?
      err.sc = sc.INPUT_ERROR
    return err 

  #------

  __set_out_encoding : () ->
    if (m = @req.path.match /\.(json|msgpack|msgpack64)$/)
      @out_encoding = m[1]

  #------
  
  __handle_input : (cb) ->
    @input = @req.body
    @__set_out_encoding()
    @set_ok() unless (err = @__check_inputs())? 
    cb err

  #------

  _handle_err : (cb, err) -> cb err

  #------
  
  __handle_stage_2: (e1, cb) ->
    if e1?
      await @_handle_err defer(e2), e1
    else
      await @_handle defer e2
    cb e2

  #------

  __err_to_http_and_json : (err) ->
    if err?
      code = err.sc or sc.GENERIC_ERROR
      @set_error code, err.message 
      @http_out_code = c if (c = err.http_code)?
      log.warn "Error #{code}: #{err.message}"

  #------
  
  __handle_stage_3 : (err, cb) ->
    unless @response_sent_yet
      @__err_to_http_and_json err
      await @send_res_json defer()
    cb()
   
  #==============================================
    
  @make_endpoint : (opts) ->
    (req, res) =>
      handler = new @ req, res, opts
      await handler.handle defer()

  #-----------------------------------------
    
  @bind : (app, path, methods, opts = {}) ->
    ep = @make_endpoint opts
    for m in methods
      app[m.toLowerCase()](path, ep)

#==============================================

exports.BOTH = [ "GET" , "POST" ] 
exports.GET = [ "GET" ]
exports.POST = [ "POST" ]
exports.DELETE = [ "DELETE" ]
