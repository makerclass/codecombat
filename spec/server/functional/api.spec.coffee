User = require '../../../server/models/User'
Client = require '../../../server/models/Client'
OAuthProvider = require '../../../server/models/OAuthProvider'
utils = require '../utils'
nock = require 'nock'
request = require '../request'
mongoose = require 'mongoose'
moment = require 'moment'
Prepaid = require '../../../server/models/Prepaid'

describe 'POST /api/users', ->

  url = utils.getURL('/api/users')

  beforeEach utils.wrap (done) ->
    yield utils.clearModels([User, Client])
    @client = new Client()
    @secret = @client.generateNewSecret()
    @auth = { user: @client.id, pass: @secret }
    yield @client.save()
    done()

  it 'creates a user that is marked as having been created by the API client', utils.wrap (done) ->
    json = { name: 'name', email: 'e@mail.com' }
    [res, body] = yield request.postAsync({url, json, @auth})
    expect(res.statusCode).toBe(201)
    expect(body.clientCreator).toBe(@client.id)
    expect(body.name).toBe(json.name)
    expect(body.email).toBe(json.email)
    done()
    
    
describe 'GET /api/users/:handle', ->

  url = utils.getURL('/api/users')

  beforeEach utils.wrap (done) ->
    yield utils.clearModels([User, Client])
    @client = new Client()
    @secret = @client.generateNewSecret()
    @auth = { user: @client.id, pass: @secret }
    yield @client.save()
    json = { name: 'name', email: 'e@mail.com' }
    [res, body] = yield request.postAsync({url, json, @auth})
    @user = yield User.findById(res.body._id)
    done()

  it 'returns the user, including stats', utils.wrap (done) ->
    yield @user.update({$set: {'stats.gamesCompleted':1}})
    url = utils.getURL("/api/users/#{@user.id}")
    [res, body] = yield request.getAsync({url, json: true, @auth})
    expect(res.statusCode).toBe(200)
    expect(body._id).toBe(@user.id)
    expect(body.name).toBe(@user.get('name'))
    expect(body.email).toBe(@user.get('email'))
    expect(body.stats.gamesCompleted).toBe(1)
    done()

  
describe 'POST /api/users/:handle/o-auth-identities', ->

  beforeEach utils.wrap (done) ->
    yield utils.clearModels([User, Client])
    @client = new Client()
    @secret = @client.generateNewSecret()
    yield @client.save()
    @auth = { user: @client.id, pass: @secret }
    url = utils.getURL('/api/users')
    json = { name: 'name', email: 'e@mail.com' }
    [res, body] = yield request.postAsync({url, json, @auth})
    @user = yield User.findById(res.body._id)
    @url = utils.getURL("/api/users/#{@user.id}/o-auth-identities")
    @provider = new OAuthProvider({lookupUrlTemplate: 'https://oauth.provider/user?t=<%= accessToken %>'})
    @provider.save()
    @json = { provider: @provider.id, accessToken: '1234' }
    @providerRequest = nock('https://oauth.provider').get('/user?t=1234')
    done()

  it 'adds a new identity to the user if everything checks out', utils.wrap (done) ->
    @providerRequest.reply(200, {id: 'abcd'})
    [res, body] = yield request.postAsync({ @url, @json, @auth })
    expect(res.statusCode).toBe(200)
    expect(res.body.oAuthIdentities.length).toBe(1)
    expect(res.body.oAuthIdentities[0].id).toBe('abcd')
    expect(res.body.oAuthIdentities[0].provider).toBe(@provider.id)
    done()

  it 'returns 404 if the user is not foud', utils.wrap (done) ->
    url = utils.getURL("/api/users/dne/o-auth-identities")
    [res, body] = yield request.postAsync({ url, @json, @auth })
    expect(res.statusCode).toBe(404)
    done()

  it 'returns 403 if the client did not create the given user', utils.wrap (done) ->
    user = yield utils.initUser()
    url = utils.getURL("/api/users/#{user.id}/o-auth-identities")
    [res, body] = yield request.postAsync({ url, @json, @auth })
    expect(res.statusCode).toBe(403)
    done()

  it 'returns 422 if "provider" and "accessToken" are not provided', utils.wrap (done) ->
    json = {}
    [res, body] = yield request.postAsync({ @url, json, @auth })
    expect(res.statusCode).toBe(422)
    done()

  it 'returns 404 if the provider is not found', utils.wrap (done) ->
    json = { provider: new mongoose.Types.ObjectId() + '', accessToken: '1234' }
    [res, body] = yield request.postAsync({ @url, json, @auth })
    expect(res.statusCode).toBe(404)
    done()

  it 'returns 422 if the token lookup fails', utils.wrap (done) ->
    @providerRequest.reply(400, {})
    [res, body] = yield request.postAsync({ @url, @json, @auth })
    expect(res.statusCode).toBe(422)
    done()

  it 'returns 409 if a user already exists with the given id/provider', utils.wrap (done) ->
    yield utils.initUser({oAuthIdentities: [{ provider: @provider._id, id: 'abcd'}]})
    @providerRequest.reply(200, {id: 'abcd'})
    [res, body] = yield request.postAsync({ @url, @json, @auth })
    expect(res.statusCode).toBe(409)
    done()

    
describe 'POST /api/users/:handle/prepaids', ->

  beforeEach utils.wrap (done) ->
    yield utils.clearModels([User, Client])
    @client = new Client()
    @secret = @client.generateNewSecret()
    yield @client.save()
    @auth = { user: @client.id, pass: @secret }
    url = utils.getURL('/api/users')
    json = { name: 'name', email: 'e@mail.com' }
    [res, body] = yield request.postAsync({url, json, @auth})
    @user = yield User.findById(res.body._id)
    @url = utils.getURL("/api/users/#{@user.id}/prepaids")
    @endDate = moment().add(12, 'months').toISOString()
    @json = { @endDate }
    done()

  it 'provides the user with premium access until the given endDate, and creates a prepaid', utils.wrap (done) ->
    expect(@user.hasSubscription()).toBe(false)
    t0 = new Date().toISOString()
    [res, body] = yield request.postAsync({ @url, @json, @auth })
    t1 = new Date().toISOString()
    expect(res.body.subscription.ends).toBe(@endDate)
    expect(res.statusCode).toBe(200)
    prepaid = yield Prepaid.findOne({'redeemers.userID': @user._id})
    expect(prepaid).toBeDefined()
    expect(prepaid.get('clientCreator').equals(@client._id)).toBe(true)
    expect(prepaid.get('redeemers')[0].userID.equals(@user._id)).toBe(true)
    expect(prepaid.get('startDate')).toBeGreaterThan(t0)
    expect(prepaid.get('startDate')).toBeLessThan(t1)
    expect(prepaid.get('endDate')).toBe(@endDate)
    user = yield User.findById(@user.id)
    expect(user.hasSubscription()).toBe(true)
    done()

  it 'returns 404 if the user is not found', utils.wrap (done) ->
    url = utils.getURL('/api/users/dne/prepaids')
    [res, body] = yield request.postAsync({ url, @json, @auth })
    expect(res.statusCode).toBe(404)
    done()

  it 'returns 403 if the user was not created by the client', utils.wrap (done) ->
    yield @user.update({$unset: {clientCreator:1}})
    [res, body] = yield request.postAsync({ @url, @json, @auth })
    expect(res.statusCode).toBe(403)
    done()

  it 'returns 422 if the endDate is not provided or incorrectly formatted', utils.wrap (done) ->
    json = {}
    [res, body] = yield request.postAsync({ @url, json, @auth })
    expect(res.statusCode).toBe(422)

    json = { endDate: '2014-01-01T00:00:00.00Z'}
    [res, body] = yield request.postAsync({ @url, json, @auth })
    expect(res.statusCode).toBe(422)
    
    done()

  it 'returns 422 if the user already has free premium access', utils.wrap (done) ->
    yield @user.update({$set: {stripe: {free:true}}})
    [res, body] = yield request.postAsync({ @url, @json, @auth })
    expect(res.statusCode).toBe(422)
    done()

  it 'returns 422 if the user has access beyond the given endDate', utils.wrap (done) ->
    free = moment().add(13, 'months').toISOString()
    yield @user.update({$set: {stripe: {free}}})
    [res, body] = yield request.postAsync({ @url, @json, @auth })
    expect(res.statusCode).toBe(422)
    done()

  it 'sets the prepaid startDate to the user\'s old terminal subscription end date if there is one', utils.wrap (done) ->
    originalFreeUntil = moment().add(6, 'months').toISOString()
    yield @user.update({$set: {stripe: {free: originalFreeUntil}}})
    [res, body] = yield request.postAsync({ @url, @json, @auth })
    expect(res.statusCode).toBe(200)
    prepaid = yield Prepaid.findOne({'redeemers.userID': @user._id})
    expect(prepaid.get('startDate')).toBe(originalFreeUntil)
    done()
