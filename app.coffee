express = require('express')
mustache = require("./mustache.js");
io = require('socket.io')
redis = require('redis')
redis_store = require('connect-redis')(express)


tmpl = 
	compile: (source,options) ->
		if 'string' == typeof source
			(options) ->
				options.locals = options.locals || {}
				options.partials = options.partials || {}
				if options.body then locals.body = options.body
				compile_options = {}
				template = mustache.compile source, compile_options
				template options.locals,options.partials
		else
			source
	
	render: (template,options) ->
		template = this.compile(template,options)
		template(options)
	

app = module.exports = express.createServer()

viewPath = () -> __dirname + '/views'
app.configure () ->
	app.use express.bodyParser()
	app.use express.cookieParser()
	app.use express.session {secret:'ze zecret goes here',store:new redis_store()}
	app.use express.methodOverride()
	app.use app.router
	app.set 'views', viewPath()
	app.set 'view options', {layout:false}
	app.register '.html',tmpl
	app.use express.errorHandler({
		dumpExceptions: true
		showStack: true
	})

app.use express.static(__dirname+'/public')

sessions = {}
rc = redis.createClient()

generateUser =  (cb) ->
	rc.incr 'userkey',(e,obj) ->
		cb obj

getUserDetails = (uk,cb,err_cb) ->
	rc.hgetall 'uk:' + uk,(err,obj) ->
		if err? 
			if err_cb? then err_cb err
		else 
			cb(obj)

io = io.listen app
io.sockets.on 'connection', (socket) ->
	socket.on 'connect',(data) ->
		chid = data.chid
		if not sessions[chid]
			sessions[chid] = []
		sessions[chid].push socket

	socket.on 'message',(data) ->
		chid = data.chid
		rc.lpush 'session:' + chid,JSON.stringify data

		if sessions[chid]?
			for s in sessions[chid]
				s.emit 'message',data

app.get '/', (req,resp) ->
	resp.render 'index.html'

app.get '/:chid/history', (req,resp) ->
	chid = req.params.chid
	history = []
	rc.lrange 'session:' + chid,0,100,(e,objlist) ->
		if e?
			console.log 'Error',e
		else
			for obj in objlist
				history.push JSON.parse obj
		resp.json history

app.get '/updateuser/:userkey', (req,resp) ->
	if not req.session.userkey?
		resp.json({"error":"no such user"},400)
	name = req.query.name
	rc.hset 'uk:' + req.session.userkey,'name',name
	getUserDetails req.session.userkey,(obj) ->
			req.session.user = obj
			resp.json({"status":"ok"},200)
		,(err) ->
			console.log 'error',err
			resp.json(err,400)

app.get '/:chid', (req,resp) ->
	handler = (req,resp) ->
		ch_id = req.params.chid
		history = []
		rc.lrange 'session:' + ch_id,0,10,(e,objlist) ->
			if e?
				console.log 'Error',e
			else
				for obj in objlist
					history.push
						'item':obj
			resp.render 'ch.html', {locals:{'chid':ch_id,'userkey':req.session.userkey,'user':req.session.user ? {}}}
	if not req.session.userkey?
		console.log 'generating userkey'
		generateUser (key) ->
			req.session.userkey = key
			handler req,resp
	else
		console.log 'got user key',req.session.userkey
		handler req,resp


app.listen 81