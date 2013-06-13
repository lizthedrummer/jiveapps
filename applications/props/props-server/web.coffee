#   Copyright 2013 Jive Software
# 
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
# 
#      http://www.apache.org/licenses/LICENSE-2.0
# 
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.

# Require Vendor Libraries
#
$            = require "jquery"
coffeescript = require "coffee-script"
crypto       = require "crypto"
express      = require "express"
fs           = require "fs"
request      = require "request"
im           = require "imagemagick"
log          = require "util"

# Require Project Libraries
#
init       = require "./init.js"
oauth      = require "./oauth.js"
opensocial = require "./opensocial.js"
DB         = require "./db_postgres.coffee"
activity   = require "./activity.coffee"
util       = require './util.js'
proptypes  = require "./defproptypes.js"

# App OAuth Credentials
#
prodAppId = "6e966b7a-2e6e-4eeb-9f71-9c2b2d9b1b3f"
oauthCreds =
  "6e966b7a-2e6e-4eeb-9f71-9c2b2d9b1b3f":
    id: "<app-id>",
    key: "<key>",
    secret: "<secret>",
    gateway: "http://gateway.jivesoftware.com",
    description: "PRODUCTION, DO NOT MODIFY"

# Authenticate OAuth Request
#
authenticate = (request, response, next) ->
  request.on "end", ->
    oauthobj = new oauth.OAuth(undefined, undefined, oauthCreds.key, oauthCreds.secret, "1.0", undefined, "HMAC-SHA1", undefined)
    log.debug oauthobj
    verified = oauthobj.verifySignature("http://" + request.headers.host + request.url)
    message = (if verified then "Success. Signature Verified!" else "Failure. Signatures do not match!")
    response.writeHead 200,
      "Content-Length": message.length

    response.write message
    response.end()

  next()


# Handle OAuth errors by returning a 401 status and JSON representation of error object
#
handleError = (error, request, response, next) ->
  if error instanceof oauth.OAuthError
    log.debug "OAuth Error: ", error
    response.statusCode = 401
    response.end '{ error: "' + error.message + '" }'
  else
    next error

handlePostgresDbErrors = (error, request, response, noSuchDomainResponse=[]) ->
  if error && error.code=="42P01" #42P01 is postgres error code for table does not exist
    log.debug "No such table exists for this Jive instance, sending empty array."
    response.send error, 400
  else
    response.send error, 400


# Lookup oauth keys...
#
oauthLookup = (request, type, appId, callback) ->
  if type is "token"
    callback ""
  else if type is "client"
    if oauthCreds[appId]
      callback oauthCreds[appId].secret;
    else
      log.debug "Lookup for unknown " + appId + " attempted."
      callback ""
  else
    log.debug "Unknown secret type ", type

# Setup Webserver
#
app = express.createServer(express.logger())

# Setup Web App Middleware
#
app.use oauth.parseHeader()
app.use opensocial.parseParams(oauthCreds[prodAppId].key)
app.use express.bodyParser()
app.use express.methodOverride()
app.use express.static(__dirname + '/public')
app.use setContentType = (req, res, next) ->
  res.header "Content-Type", "application/json"
  next()

app.error handleError

download = (uri, filename) ->
  filename = __dirname+'/public/img/prop_types/'+filename;
  log.debug("image download:", uri, "->", filename)
  req = request(uri).pipe(fs.createWriteStream(filename))
  req.on('finish', () ->
    log.debug("got image");
    im.resize({
      srcPath:filename,
      dstPath:filename,
      width:128
    }, (err) ->
      if err
        log.debug("resize image err: "+err);
      else
        log.debug("saved!");
    );
  );

undownload = (filename, callback) ->
  fs.unlink(__dirname+'/public/img/prop_types/'+filename, callback);

# ########## App Routes ###########

app.get "/instances/register", (req, res) ->
  if req.query.jiveInstanceId
    DB.Instances.register(req.query.jiveInstanceId, (err) ->
      if err
        res.send "Registration failed", 500
      else
        res.send "Successfully registered jive Instace #{req.query.jiveInstanceId} into props app!", 200
    );
  else
    res.send "Need jive Instance id!", 400

# ### Prop Types ###

# GET /props/types
# Get default prop types, optionally filter by current request level
#
app.get "/props/types", oauth.verifySignature(oauthLookup), (req, res) ->
  DB.PropType.findAllByLevel req.opensocial.getJiveId(), req.query.level, (error, result) ->
    if error
      res.send error, 400
    else
      res.send result, 200

app.get "/props/types/reset", oauth.verifySignature(oauthLookup), (req, res) ->
  DB.PropType.resetTable(req.opensocial.getJiveId())
  res.send("Resetting prop types.\n")

# GET /testRemove
# testing for removing a prop type
app.get "/testRemove", oauth.verifySignature(oauthLookup), (req,res) ->
  log.debug("testRemove: ", typeof(req.query), req.query)
  DB.PropType.findByName req.opensocial.getJiveId(), req.query.type, (error, propTypeResult) ->
    if (error)
      res.send error, 400
    else
      if (propTypeResult)
        res.send "to delete:"+propTypeResult.$ItemName, 200
      else
        res.send "does not exist:"+req.query.type, 200

# GET /props/types/remove
# Remove the specified prop type, specified by query param 'type'
app.get "/props/types/remove", oauth.verifySignature(oauthLookup), (req,res) ->
  log.debug("remove prop type request: "+req)
  jiveInstanceid = req.opensocial.getJiveId();
  DB.PropType.findById jiveInstanceid, req.query.type, (error, propTypeResult) ->
    if error
      res.send error, 400
    else
      if propTypeResult
        DB.PropType.delete jiveInstanceid, propTypeResult.$ItemName, (error) ->
          if error
            res.send error, 400
          else
            undownload util.stringHash(propTypeResult.title+jiveInstanceid)+'.png', (err) ->
              if (err)
                res.send err, 200
              else
                res.send "successfully removed prop type "+req.query.type, 200
      else
        res.send "already removed: "+req.query.type, 200

# POST /props/types
# Create a new type of prop, or modify an existing prop type
# prop types are uniquely identified by name.
app.post "/props/types", oauth.verifySignature(oauthLookup), (req, res) ->
  log.log("create new prop type request: "+req.body)
  body = req.body
  if (body.title && body.definition && body.image_url && body.level)
    jiveInstanceid = req.opensocial.getJiveId();
    download(body.image_url, util.stringHash(body.title+jiveInstanceid)+'.png')
    body.image_url = body.reflection_image_url = exports.BASE_URL+'/img/prop_types/'+util.stringHash(body.title+jiveInstanceid)+'.png'
    DB.PropType.modify(jiveInstanceid, body, (error, result) ->
      if error
        res.send error, 400
      else if result == null
        res.send "", 404
      else
        DB.PropType.findByName(jiveInstanceid, body.title, (error, propTypeResult) ->
          if error
            res.send error, 400
          else
            res.send propTypeResult, 200
        );
    );
  else
    res.send "bad request: "+JSON.stringify(req), 400

# GET /props
# Get all props for a user
# Filter by
#   user_id   - id of the user the prop belongs to. defaults to owner id
#   giver_id  - id of the user who gave the prop
#   prop_type - the type of prop
#
app.get "/props", oauth.verifySignature(oauthLookup), (req, res) ->
  options = $.extend({}, req.query)
  options.jiveInstanceId = req.opensocial.getJiveId()
  options.ownerId = req.opensocial.getOwnerId()

  DB.Prop.findAll options, (error, result, meta) ->
    if error
      handlePostgresDbErrors error, req, res
    else
      res.send result

# GET /props/count?prop_type=propname
# Return count of props for viewer based on prop name.
# Filter by
#   user_id   - id of the user the prop belongs to
#   giver_id  - id of the user who gave the prop
#   prop_type - the type of prop
#   days_ago  - number of days back to count
#
app.get "/props/count", oauth.verifySignature(oauthLookup), (req, res) ->
  options = $.extend({}, req.query)
  options.ownerId = req.opensocial.getOwnerId()

  DB.Prop.count req.opensocial.getJiveId(), options, (error, result, meta) ->
    if error
      handlePostgresDbErrors error, req, res
    else
      res.send result

# GET /props/stream
# Get the streams of props given during certain period from the request.
#
app.get "/props/stream", oauth.verifySignature(oauthLookup), (req, res) ->
  options = $.extend({}, req.query)

  DB.Prop.stream req.opensocial.getJiveId(), options, (error, result, meta) ->
    if error
      handlePostgresDbErrors error, req, res
    else
      res.send result

# GET /props/:id
# Get a prop by its id
#
app.get "/props/:id", oauth.verifySignature(oauthLookup), (req, res) ->
  DB.Prop.find req.opensocial.getJiveId(), req.params.id, (error, result, meta) ->
    if error
      res.send error, 400
    else if result == null
      res.send "", 404
    else
      res.send result

# POST /props
# Create a prop
#
app.post "/props", oauth.verifySignature(oauthLookup), (req, res) ->
  propObj = $.extend(req.body, {giver_id: req.opensocial.getOwnerId()});

  # disallow self propping
  if propObj.giver_id == propObj.user_id
    return res.send { error: "Forbidden: Just do it in your mind, not so publicly" }, 403

  propObj.message = util.escapeMessage propObj.message
  DB.Prop.createProp(req.opensocial.getJiveId(), propObj, (err, result) ->
    if err
      res.send err, 400
    else
      DB.PropType.findById req.opensocial.getJiveId(), propObj.prop_type, (err1, propTypeResult) ->
        propImageUrl = propTypeResult.image_url
        # creds = oauthCreds[req.opensocial.getAppId()]
        # activity.postProp req.opensocial.getJiveId(), propObj, propImageUrl, creds
        res.send result, 201
  );

app.post "/debugPost", (req, res) ->
  log.debug(typeof(req.body), req.body)
  obj =
    body: req.body
    params: req.params
    headers: req.headers
    query: req.query
  res.send obj

app.get "/keys", (req, res) ->
  pubCreds = {}
  $.extend(true, pubCreds, oauthCreds)
  for id of pubCreds
    delete pubCreds[id]['secret']
  res.send JSON.stringify(pubCreds, null, 4), 200

app.put "/keys/:app_id", (req, res) ->
  devAppKeys = req.body
  if req.params.app_id && devAppKeys.key && devAppKeys.secret
    if req.params.app_id == prodAppId
      res.send 403
    else
      devAppKeys.gateway = oauthCreds[prodAppId].gateway unless devAppKeys.gateway
      devAppKeys.id = req.params.app_id
      oauthCreds[req.params.app_id] = devAppKeys
      res.send 201
  else
    res.send "app id, key & secret are required.", 400

app.delete "/keys/:app_id", (req, res) ->
  devAppKeys = req.body
  if req.params.app_id == prodAppId
    res.send 403
  else
    delete oauthCreds[req.params.app_id]
    res.send 200


app.get "/manage/help", (req, res) ->
  res.send("Jive Props App Backend Server\n
  Public Endpoints:
  GET /instances/register to register a new Jive Instance into the Props App Database.\n
  POST /props to create a prop\n
  GET /props to get all props for a user\n
  GET /props/stream to get recent props\n
  GET /props/count to get the number of props with given parameters\n
  POST /props/types to create a prop type\n
  GET /props/types to view prop types\n
  GET /props/types/remove to remove a prop type\n
  GET /props/types/reset to reset prop types for a jive instance to deafult
  Must be called from Jive App with Registered OAuth key and secret.", 200)

app.get "/manage/ping", (req, res) ->
  res.send 200

app.get "/manage/version", (req, res) ->
  res.send("1.1.0", 200)

app.get "/manage/health/check", (req, res) ->
  require("./dbhealth_postgres.js").healthTest((result, code) ->
    res.send(result,200)
  );

app.get "/manage/health/connectivity", (req, res) ->
  require("./dbhealth_postgres.js").connectivityCheck (result, code) ->
    res.send(result,200)

app.get "/manage/health/metrics", (req, res) ->
  require("./dbhealth_postgres.js").getStats((result, code) ->
    res.send(result,200)
  );

app.get "/manage/health/shutdown", (req, res) ->
  res.send("Shutting down...", 200);
  process.exit();

# Listen for requests on the specified port
#
port = process.env.PORT or 5000
log.debug("about to listen...")
app.listen port, ->
  DB.env process.env.NODE_ENV # Set db environment (development/production/etc)
  log.debug "Running in #{DB.env()} mode, listening on #{port}"