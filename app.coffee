express = require('express')
mustache = require("./mustache.js");
io = require('socket.io')
redis = require('redis')
redis_store = require('connect-redis')(express)
bcrypt = require('bcrypt')



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

EH = (resp) ->
	(e) ->
		resp.json e,500
		
generateID = (prefix,cb) ->
	rc.incr prefix, (e,uk) ->
		cb e,uk

###
generateUser =  (e,cb) ->
	generateID 'userkey',e,() ->
		rc.incr 'userkey',(e,uk) ->
			rc.hset 'uk:' + uk,'userkey',uk
			rc.lpush 'global.users',uk
			cb uk

###
ERR = (msg) ->
	{'message':msg}
createRoom = (details,cb) ->
	if not details.name then cb ERR 'No name specified for the room'
	if not details.created_userkey then cb ERR 'No created user specified'
	name = details.name
	uk = details.created_userkey

	await generateID 'room',defer e,rk
	if e? then return cb e

	rc.hset 'room:' + rk,'roomkey',rk
	rc.hset 'room:' + rk,'created_userkey',uk
	rc.hset 'room:' + rk,'name',name
	rc.sadd 'room.users:' + rk,uk
	cb null,rk

roomHasUser = (rk,uk,cb) ->
	await rc.sismember 'room.users:' + rk,uk,defer e,exists
	if e? then return cb e
	return cb null,exists==1


createUser = (details,cb) ->
	if not details.email then return cb ERR 'No email address specified'

	email = details.email

	await rc.sismember 'emails',email,defer e,exists
	if exists == 1 then return cb ERR "Email address #{email} exists"

	await rc.sadd 'emails',email,defer e,ok

	await generateID 'userkey',defer e,uk
	if e? then return cb e,null

	await bcrypt.genSalt 10, defer e,salt
	if e? then return cb e,null
	console.log 'my salt',salt

	await bcrypt.hash details.password,salt,defer e,hash
	if e? then return cb e,null

	rc.hset 'user:' + uk,'userkey',uk
	rc.hset 'user:' + uk,'name',details.name
	rc.hset 'user:' + uk,'password',hash
	rc.hset 'user:' + uk,'email',email

	rc.set 'useremail:' + email,uk
	user = 
		userkey: uk
		name: details.name
		password: hash
		email: email
	
	return cb null,user

verifyUser = (email,password,cb) ->
	await rc.get 'useremail:' + email, defer e,uk
	if e? then return cb e,null

	if not uk then return cb ERR 'No such user'


	await rc.hgetall 'user:' + uk,defer e,user
	if e? then return cb e,null
	
	actual_password = user.password

	await bcrypt.compare password,actual_password, defer e,ok
	if e? then return cb e,null

	if not ok then return cb ERR 'Invalid email address or password'

	cb null,user

createUserSession = (uk,cb) ->
	await generateID 'session',defer e,sid
	if e? then return cb e

	#TODO: expiry?
	rc.set 'sesssion:' + sid,uk,defer e,r
	if e? then return cb e

	return cb null,sid


getUserDetails = (uk,cb,err_cb) ->
	rc.hgetall 'uk:' + uk,(err,obj) ->
		if err? 
			if err_cb? then err_cb err
		else 
			cb(obj)

fillMessageData = (messages,cb) ->
	console.log 'fillin message',messages
	multi = rc.multi()
	uklist = {}
	for msg in messages
		if uklist[msg.userkey]? then continue
		multi.hgetall 'user:' + msg.userkey
		uklist[msg.userkey] = '1'
	multi.exec (err,replies) ->
		i = 0
		console.log 'multireplies',replies
		ukmap = {}
		for r in replies
			ukmap[r.userkey] = r.name
		for msg in messages
			messages[i].username = ukmap[messages[i].userkey]
			i += 1
		cb(messages)

pushMessage = (message) ->
	chid = message.chid
	if not sessions[chid]? then return
	fillMessageData [message],(messages) ->
		for s in sessions[chid]
			for m in messages
				s.emit 'message',m

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
		pushMessage data


app.get '/', (req,resp) ->
	resp.render 'index.html'

app.post '/createuser', (req,resp) ->
	un = req.query.name
	pwd = req.query.password
	email = req.query.email
	await createUser {name:un,password:pwd,email:email},defer e,user
	if e?
		resp.json e,500
		return
	resp.json user


authUser = (req,resp,next) ->
	s = req.session?.sessionid
	if not s? 
		req.session?.sessionid = null
		req.session?.user = null
		resp.redirect('/login?next=' + encodeURIComponent(req.path))
	else 
		next()

app.get '/:chid/history', (req,resp) ->
	chid = req.params.chid
	history = []
	rc.lrange 'session:' + chid,0,100,(e,objlist) ->
		if e?
			console.log 'Error',e
			resp.json e
			return
		else
			objlist = (JSON.parse obj for obj in objlist)
			fillMessageData objlist,(messages) ->
				for obj in messages
					history.push  obj
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

app.get '/login', (req,resp) ->
	next = req.query.next
	resp.render 'login.html',{locals:{next:next}}
app.post '/login', (req,resp) ->
	console.log req.body
	login = req.body.login
	next = req.body.next
	pwd = req.body.password
	await verifyUser login,pwd,defer e,user
	console.log 'user verified',e,user
	if e?
		resp.render 'login.html',{locals:{'error':e,'login':login,next:next}}
		return
	await createUserSession user.userkey,defer e,sid
	if e?
		resp.render 'login.html',{locals:{'error':e,'login':login,next:next}}
		return
	req.session.user = user
	req.session.sessionid = sid
	resp.redirect(next)
app.post '/signup', (req,resp) ->
	login = req.body.newlogin
	password = req.body.newpassword
	name = req.body.newname
	next = req.body.next

	err_handler = (e) ->
		resp.render 'login.html',{locals:{newlogin:login,newname:name,next:next,signuperror:e}}

	if not name then return err_handler ERR 'Name is required'
	if not login then return err_handler ERR 'A valid email address is required'
	
	await createUser {'name':name,'email':login,password:password}, defer e,user
	if e? then return err_handler e
	await createUserSession user.userkey,defer e,sid
	if e? then return err_handler e
	req.session.user = user
	req.session.sessionid = sid
	resp.redirect next


app.get '/:chid', authUser,(req,resp) ->
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
			resp.render 'ch.html', {locals:{'chid':ch_id,'userkey':req.session.user.userkey,'user':req.session.user ? {}}}
	console.log 'got user key',req.session.userkey
	handler req,resp


###
createUser {'name':'hs','password':'password','email':'h.shivanan@gmail.com'},(e,details) ->
	if e? then console.log 'Error',e
	else console.log 'created user',details
await verifyUser 'shivanan@statictype.org','pas1sword',defer e,user
if e? then console.log 'Error',e
else console.log 'Valid User',user
###
app.listen 81