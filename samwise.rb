#!/usr/bin/ruby
require "github_api"
require "mongo"
require 'faraday-http-cache'
require 'moneta'
require 'active_support/cache/moneta_store'

class Samwise
	include Mongo

	def initialize
		@token = ENV["GITHUB_TOKEN"]
		@user = ENV["GITHUB_USER"]
		@repo = ENV["GITHUB_REPO"]
		@org = ENV["GITHUB_ORG"]
		@dbhost = ENV["MONGO_HOST"]
		@dbport = ENV["MONGO_PORT"]
		@dbname = ENV["MONGO_DBNAME"]
	
		@store = ActiveSupport::Cache::MonetaStore.new store: :LRUHash

		@github = Github.new(oauth_token:@token, user:@user, repo:@repo, org:@org) do
			|config| config.stack.insert_before Github::Response::Jsonize, Faraday::HttpCache, @store
		end
		@db = MongoClient.new(@dbhost, @dbport).db(@dbname)
	end
	
	def processIssue(issue)
		storedIssue = @db["issues"].find_one("number" => issue.number)
		issueHash = issue.to_hash()
		if !(storedIssue && storedIssue["updated_at"] == issue.updated_at) then
			issueHash["events"] = @github.issues.events.list("acres4", "documentation", issue_id:issue.number).inject([]) { |ary, event| ary.push(event.to_hash)}
			puts "\t\##{issue.number} \"#{issue.title}\" #{issue.state}"
			if storedIssue then
				# We already knew about this issue, but it's been modified.
				
				# We will add comments for some of the changes we observe; comment text goes in the remarks array.
				remarks = []

				# If the milestone has changed, note it
				if issueHash["milestone"]["title"] != storedIssue["milestone"]["title"] then 
					remarks.push("* _Milestone changed from_ #{storedIssue["milestone"]["title"]} _to_ #{issueHash["milestone"]["title"]}")
				end
				
				# If the assignee changed, that's worth remarking upon.
				if issueHash["assignee"]["login"] != storedIssue["assignee"]["login"] then
					remarks.push("* _Assignee changed from_ @#{storedIssue['assignee']['login']} _to_ @#{issueHash['assignee']['login']}")
				end
				
				# Figure out which labels were added and removed.
				labelDifference = {
					'removed' => storedIssue["labels"].select { |label| !issueHash["labels"].include?(label) },
					'added' => issueHash["labels"].select { |label| !storedIssue["labels"].include?(label) }
				}
				
				# Now store those changes in the hash.
				issueHash["labelEvents"] = storedIssue["labelEvents"]
				["removed", "added"].each do |action|
					labelDifference[action].each do |label|
						issueHash["labelEvents"].push({label:label, action:action, date:issueHash["updated_at"]})
						remarks.push("* _#{action.capitalize} label_ **#{label['name']}**")
					end
				end
				
				# Now see if any comments were added or deleted. We won't ask for comment data, to save API calls.
				issueHash["commentEvents"] = storedIssue["commentEvents"]
				if storedIssue["comments"] != issueHash["comments"] then
					issueHash["commentEvents"].push({"count" => issueHash["comments"]-storedIssue["comments"], "timestamp" => issueHash["updated_at"]})
				end
				
				# Add the remarks to Github
				if remarks.length > 0 then
					joinedRemarks = remarks.join("\n");
					timestamp = DateTime.parse(issueHash["updated_at"]).strftime("%A, %B %e, %l:%M %P, %Z")
					commentBody = "#{timestamp}\n#{joinedRemarks}"
					@github.issues.comments.create(@user, @repo, issue.number, body:commentBody)
				end
				
				# Store changes to the database
				@db["issues"].update({"number" => issue.number}, issueHash)
			else
				# This is a new issue.
				
				issueHash["labelEvents"] = issueHash["labels"].inject([]) { |a, label| a.push({ label:label, action:"added", date:issueHash["created_at"] }) }
				issueHash["commentEvents"] = []
				if issueHash["comments"] > 0 then
					issueHash["commentEvents"].push({ "count" => issueHash["comments"], "timestamp" => issueHash["created_at"] })
				end
				@db["issues"].insert(issueHash)
			end
		end
	end
	
	def update
		# List all issues in the repo, then iterate over them and process them individually.
		# Github makes us ask for open and closed separately.
		[ "open", "closed" ].each { |state| @github.issues.list(repo:@repo, user:@user, state:state, auto_pagination:true).each { |issue| processIssue(issue) }}
	end
end


samwise = Samwise.new
loop do
	startTime = Time.new
	samwise.update()
	endTime = Time.new
	puts "Updated; took #{endTime-startTime}s\n"
	sleep(60)
end
