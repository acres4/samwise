#!/usr/bin/ruby
require "github_api"
require "mongo"
require "date"
require 'net/smtp'
require 'rest-client'
require 'json'

class GrindReport
	include Mongo
	
	def initialize
		@token = ENV["GITHUB_TOKEN"]
		@user = ENV["GITHUB_USER"]
		@repo = ENV["GITHUB_REPO"]
		@org = ENV["GITHUB_ORG"]
		@dbhost = ENV["MONGO_HOST"]
		@dbport = ENV["MONGO_PORT"]
		@dbname = ENV["MONGO_DBNAME"]
		@mailgunKey = ENV["MAILGUN_API_KEY"]
		@mailgunDomain = ENV["MAILGUN_DOMAIN"]
		@mailgunFrom = ENV["MAILGUN_FROM"]
	
		@github = Github.new(oauth_token:@token, user:@user, repo:@repo, org:@org)
		@db = MongoClient.new(@dbhost, @dbport).db(@dbname)
	end
	
	def sendRecap(interval=86400) # 86400 = 24 hours in seconds
		issuesByMilestone = {}
		orphanedIssues = []

		people = @db["people"].find().to_a
		issues = @db["issues"].find().to_a
		
		issues.each do |issue|
			next unless dateStringInInterval(issue["updated_at"], interval)
			if issue["milestone"] then
				issuesByMilestone[issue["milestone"]["title"]] ||= {}
				milestone = issuesByMilestone[issue["milestone"]["title"]]
				cat = getIssueCategory(issue, interval)
				milestone[cat] ||= []
				milestone[cat].push(issue)
			else
				orphanedIssues.push(issue) unless issue["state"] == "open"
			end
		end
		
		report = renderReport(issuesByMilestone, orphanedIssues)
		people.each do |person|
			puts "Sending to #{person['email']} (@#{person['login']})"
			personalReport = report.sub("___PERSONAL_SECTION___", renderPersonal(person["login"], issues))
			#puts personalReport
			sendEmail("Daily grind report", personalReport, [person["email"]])
		end
	end
	
	def renderReport(issuesByMilestone, orphanedIssues)
		milestoneData = @github.issues.milestones.list("acres4", "documentation")
		s = "<html><head><style>#{stylesheet}</style></head><body><h1>Grind report for #{Time.now.strftime('%A, %B %e')}</h1>\n"
		milestoneActivityCounts = milestoneData.inject([]) { |counts, milestone| counts.push({ milestone:milestone, count:eventsForMilestone(issuesByMilestone[milestone.title])})}
		milestoneActivityCounts.sort! { |a, b| b[:count] <=> a[:count] }
		milestoneActivityCounts.each do |milestoneCount|
			milestone = milestoneCount[:milestone]
			s += renderMilestone(milestone, issuesByMilestone[milestone.title])
		end
		
		s += renderOrphanedIssues(orphanedIssues) if orphanedIssues.length > 0
		
		s += "___PERSONAL_SECTION___\n"
		
		s += "</body></html>"
		
		return s
	end
	
	def renderPersonal(login, issues)
		opened = []
		s = "<div class=\"personal\">\n"
		s += "<h1>Now Let's Talk About You, <a href=\"https://github.com/#{login}\">#{login}</a></h1>\n"
		
		openIssues = issues.select { |issue| issue["state"] == "open" }
		openIssues.sort! { |a, b| b["updated_at"] <=> a["updated_at"] }
		
		assigned = openIssues.select do |issue|
			issue["assignee"] && issue["assignee"]["login"] == login
		end
		
		mentioning = openIssues.select do |issue|
			(issue["events"].index { |event| event["actor"]["login"] == login && event["event"] == "mentioned" }) != nil
		end
		
		opened = openIssues.select do |issue|
			issue["user"] && issue["user"]["login"] == login
		end
		
		s += "<div class=\"section assigned\">\n"
		s += "<h2>Issues assigned to you (<span class=\"count\">#{assigned.count}</span>)</h2><ul class=\"issues\">\n"
		assigned.each { |issue| s += renderIssueLine(issue) }
		s += "</ul></div>\n"
		s += "<div class=\"section mentioning\">\n"
		s += "<h2>Issues mentioning you (<span class=\"count\">#{mentioning.count}</span>)</h2><ul class=\"issues\">\n"
		mentioning.each { |issue| s += renderIssueLine(issue) }
		s += "</ul></div>\n"
		s += "<div class=\"section opened\">\n"
		s += "<h2>Issues opened by you (<span class=\"count\">#{opened.count}</span>)</h2><ul class=\"issues\">\n"
		opened.each { |issue| s += renderIssueLine(issue) }
		s += "</ul></div>\n"

		s += "</div>\n"
		
		return s
	end
	
	def renderOrphanedIssues(orphanedIssues)
		s = ""
		s += "<div class=\"orphaned\">\n"
		s += "<h1>Orphaned Issues</h1>\n"
		s += "<p>The following issues don't have milestones attached to them, and might be hard to find in Github.</p>\n"
		s += "<ul class=\"issues\">\n"
		orphanedIssues.each { |issue| s += renderIssueLine(issue) }
		s += "</ul>\n"
	end
	
	def renderIssueLine(issue)
		if issue['labels'].length > 0 then
			labels = (issue['labels'].inject([]) { |a, label| a.push(label["name"])}).join(", ")
		else
			labels = "no labels"
		end
		
		classes = [ "issue" ]
		classes.push "active" if dateStringInInterval(issue["updated_at"], 86400)
		milestone = issue['milestone'] ? issue['milestone']['title'] : 'No milestone'
		"<li class=\"#{classes.join(' ')}\"><a href=\"#{issue['html_url']}\">\##{issue['number']}</a>: #{issue['title']} <span class=\"labels\">(<i>#{labels}</i>)</span> <span class=\"milestoneTag\">[<i>#{milestone}</i>]</span></li>\n"
	end
	
	def eventsForMilestone(milestone)
		return 0 unless milestone
		s = 0
		milestone.each { |k, v| s += milestone[k].length }
		return s
	end
	
	def renderMilestone(milestone, issues)
		s = "<div class=\"milestone\"><h2><a href=\"https://github.com/#{@user}/#{@repo}/issues?milestone=#{milestone.number}&state=open\">#{milestone.title}</a>, #{(100.0*milestone.closed_issues/(milestone.open_issues+milestone.closed_issues)).round(0)}%</h2>\n"
		s += "<p class=\"overall_class\"><b>#{milestone.open_issues}</b> open, <b>#{milestone.closed_issues}</b> closed</p>\n"
		if issues then
			s += renderMilestoneIssues(issues, "new")
			s += renderMilestoneIssues(issues, "reopened")
			s += renderMilestoneIssues(issues, "active")
			s += renderMilestoneIssues(issues, "resolved")
			s += renderMilestoneIssues(issues, "closed")
		else
			s += "<p class=\"no_activity\"><i>No activity today.</i></p>\n"
		end
		s += "</div>\n"
		return s
	end
	
	def renderMilestoneIssues(milestone, section)
		s = "<h3>#{section.capitalize}</h3>\n<ul class=\"issues\">"
		return "" unless milestone[section]
		milestone[section].each { |issue| s += renderIssueLine(issue) }		
		s += "</ul>\n"
		
		return s
	end
	
	def getIssueCategory(issue, interval)
		if(issue["state"] == "open") then
			return "resolved" if issueAddedLabelInInterval(issue, "resolved", interval)
			return "new" if dateStringInInterval(issue["created_at"], interval)
			return "reopened" if issueHasEventInInterval(issue, "reopened", interval)
		else
			return "closed" if dateStringInInterval(issue["closed_at"], interval)
		end
		
		return "active"
	end
	
	def dateStringInInterval(dateStr, interval)
		now = Time.now
		date = DateTime.parse(dateStr).to_time
		return now - date <= interval
	end

	def issueAddedLabelInInterval(issue, labelName, interval)
		issue["labelEvents"].each do |event|
			next unless event["action"] == "added"
			next unless event["label"]["name"] == labelName
			return true if dateStringInInterval(event["date"], interval)
		end
		
		return false
	end
	
	def issueHasEventInInterval(issue, eventType, interval)
		issue["events"].each do |event|
			next unless event["event"] == eventType
			return true if dateStringInInterval(event["created_at"], interval)
		end
		
		return false
	end
	
	def sendEmail(subject, body, recipients)
		url = "https://api:#{@mailgunKey}@api.mailgun.net/v2/#{@mailgunDomain}/messages"
		RestClient.post url,
			:from => @mailgunFrom,
			:to => recipients.join(", "),
			:subject => subject,
			:html => body
	end
	
	def stylesheet
		 <<CSS_END
@import url(http://fonts.googleapis.com/css?family=Roboto+Slab:300,400,700);
@import url(http://fonts.googleapis.com/css?family=Open+Sans:300);

body {
    font-family:"Open Sans", sans-serif;
    background-color:#fff;
}

h1 {
    font-family:"Roboto Slab", serif;
    font-weight:400;
    color:#111;
}

.milestone {
background: rgb(245,245,245); /* Old browsers */
background: -moz-linear-gradient(top,  rgba(245,245,245,1) 0%, rgba(242,242,242,1) 50%, rgba(239,239,239,1) 51%, rgba(255,255,255,1) 100%); /* FF3.6+ */
background: -webkit-gradient(linear, left top, left bottom, color-stop(0%,rgba(245,245,245,1)), color-stop(50%,rgba(242,242,242,1)), color-stop(51%,rgba(239,239,239,1)), color-stop(100%,rgba(255,255,255,1))); /* Chrome,Safari4+ */
background: -webkit-linear-gradient(top,  rgba(245,245,245,1) 0%,rgba(242,242,242,1) 50%,rgba(239,239,239,1) 51%,rgba(255,255,255,1) 100%); /* Chrome10+,Safari5.1+ */
background: -o-linear-gradient(top,  rgba(245,245,245,1) 0%,rgba(242,242,242,1) 50%,rgba(239,239,239,1) 51%,rgba(255,255,255,1) 100%); /* Opera 11.10+ */
background: -ms-linear-gradient(top,  rgba(245,245,245,1) 0%,rgba(242,242,242,1) 50%,rgba(239,239,239,1) 51%,rgba(255,255,255,1) 100%); /* IE10+ */
background: linear-gradient(to bottom,  rgba(245,245,245,1) 0%,rgba(242,242,242,1) 50%,rgba(239,239,239,1) 51%,rgba(255,255,255,1) 100%); /* W3C */
filter: progid:DXImageTransform.Microsoft.gradient( startColorstr='#f5f5f5', endColorstr='#ffffff',GradientType=0 ); /* IE6-9 */


    -moz-border-radius: 15px;
    border-radius: 15px;
    border: 1px solid #eee;
    
    padding: 0 10px 0 10px;
    margin-bottom:20px;
}

.milestone h2 {
    font-family:"Roboto Slab", serif;
    font-weight:300;
    color:#000;
    margin-top:0;
    padding-top:0;
    padding-bottom:0;
    margin-bottom:0;
}

.milestone h3 {
    font-family:"Roboto Slab", serif;
    color:#015C65;
    padding-bottom:0;
    margin-bottom:0;
}

.milestone span.milestoneTag {
    display:none
}

h3 a {
    color:#FF0D00;
}

h2 a {
    color:#FF0D00;
}

h1 a {
    color:#FF0D00;
}

.milestone p a {
    font-family:"Roboto Slab",serif;
    font-weight:300;
    color:#639A00
}

.milestone p a:visited {
    color:#639A00
}

p.overall_count {
    margin-top:0;
    padding-top:0;
}

.overall_count b {
    color:#015C65;
    font-size:120%;
}

ul.issues {
    list-style-type: none;
    margin-top:0;
    padding: 0px 10px 0px 10px;
}

ul.issues a {
    color:#639A00;
}

p.issues i {
    color:#aaa;
    font-size:80%;
}

.stanza {
    font-family:"Roboto Slab",serif;
    font-style:italic;
    font-size:8px;
    color:#aaa;
}

.personal h2 {
    font-family:"Roboto Slab", serif;
    font-weight:300;
    color:#000;
}

.personal li {
    color:#777;
}

.personal li.active {
    color:#000;
}

.personal span.milestoneTag {
    font-weight:bold;
}

.personal span.milestoneTag i {
    font-style:normal;
}

.section h2 {
    margin-bottom:0;
    color:#015C65;
}
.section ul {
    margin-top: 0;
    padding-top: 0;
}

.section h2 span.count {
    color:#000;
    font-weight:700;
}
CSS_END

	end
end

grind = GrindReport.new
grind.sendRecap

