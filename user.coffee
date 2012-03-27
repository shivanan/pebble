bcrypt = require('bcrypt')
app = require('./app')

authError = () ->
	e = new Error('Authentication Failed')
	e.type = 'auth'
	return e

checkPassword = (pwd,actual,cb) ->
	bcrypt.compare pwd,actual,(err,result) ->
		if err? then return cb err
		if not result then return cb authError()
		cb(null,result)

generateUserToken = (user,cb) ->
	app.generateID 'sessiontoken', (err,token) ->
		if err? then return cb err
		redis.hgetall 'user:' + user,(err,user_details) ->
			if err? then return cb err
			redis.hsetall 'sessiontoken:' + token,user_details,(err,result) ->
				if err? then return cb err
				return cb null,result

authenticateUser = (user,pwd,cb) ->
	redis.get 'user.password:' + user,(err,result) ->
		if err? then return cb err
		checkPassword pwd,result,(err,result) ->
			if err? then return cb err
			generateUserToken user,(err,result) ->
				if err? then return cb err
				cb result

createUser = (uid,pwd,handle) ->
