module DealReports
  module IndustryStrategyPlaybook
    module_function

    AUTO_VALUE = "auto".freeze
    FALLBACK_KEY = "local_services".freeze

    PROFILES = {
      "roofing" => {
        label: "Roofing",
        category: "home services",
        keywords: %w[roof roofing roofer shingles gutter siding exterior storm hail],
        input_variables: ["revenue mix: insurance vs retail", "CRM platform", "certifications", "services beyond roofing", "current seasonal focus"],
        targeting_definition: "Prioritize homes likely to have 15-25 year roof age, storm exposure, insurance claim relevance, and premium neighborhoods where exterior trust matters.",
        intelligence_tasks: ["service and seasonality snapshot", "local storm and weather risk", "roof-age targeting by ZIP", "premium neighborhood targeting", "growth/new construction pockets", "quick local brief", "campaign proposals", "CRM automation opportunities"],
        campaign_types: ["Brick by Brick", "Storm Chaser Blitz", "Age of Roof Targeting", "Seasonal Rotation Calendar", "Insurance Claims Awareness", "Neighborhood Blitz", "EDDM ZIP Saturation"],
        output_sections: ["Client & Focus", "Storm & Weather Intel", "Roof Age Targeting", "Premium Neighborhoods", "Growth & New Construction", "Quick Local Brief", "Campaigns", "CRM Automation Notes"],
        crm_automation_triggers: ["storm follow-up", "inspection booked", "estimate sent", "insurance claim conversation", "past customer anniversary"]
      },
      "hvac" => {
        label: "HVAC",
        category: "home services",
        keywords: %w[hvac heating cooling furnace air-conditioner airconditioning mechanical ventilation],
        input_variables: ["heating vs cooling demand", "maintenance plan model", "service, install, IAQ, and duct work mix", "emergency availability", "utility rebate relevance"],
        targeting_definition: "Prioritize homes with likely 15-20 year system age, climate extremes, energy cost pressure, and neighborhoods where comfort interruptions create urgent buying behavior.",
        intelligence_tasks: ["service and seasonal snapshot", "weather/temperature demand", "system age targeting", "established neighborhood targeting", "new construction and new homeowner opportunities", "quick local brief", "campaign proposals", "CRM automation opportunities"],
        campaign_types: ["Seasonal Flip", "System Age Targeting", "Maintenance Plan Push", "Emergency Breakdown Readiness", "Utility Rebate Awareness", "New Homebuyer Comfort", "Brick by Brick"],
        output_sections: ["Client & Focus", "Climate Demand", "System Age Targeting", "Neighborhood Opportunity", "New Homeowner & Growth Signals", "Quick Local Brief", "Campaigns", "CRM Automation Notes"],
        crm_automation_triggers: ["maintenance due", "no tune-up in 12 months", "estimate sent", "weather alert", "new homeowner touch"]
      },
      "plumbing" => {
        label: "Plumbing",
        category: "home services",
        keywords: %w[plumbing plumber drain sewer water-heater repipe pipe leak],
        input_variables: ["emergency vs scheduled work", "specialties", "24/7 availability", "water heater focus", "repipe or sewer capability"],
        targeting_definition: "Prioritize older homes with likely pipe risk, water heater age, water quality concerns, and urgent homeowner pain around leaks, drains, and hot water.",
        intelligence_tasks: ["service and seasonal snapshot", "water/infrastructure risk", "repipe neighborhood targeting", "water heater replacement targeting", "new buyer opportunity", "quick local brief", "campaign proposals", "CRM automation opportunities"],
        campaign_types: ["Repipe Neighborhoods", "Water Heater Countdown", "Emergency Readiness", "Seasonal Drain Campaign", "Water Quality Check", "New Homebuyer Plumbing", "Brick by Brick"],
        output_sections: ["Client & Focus", "Infrastructure & Water Risk", "Home Age Targeting", "Water Heater Opportunity", "New Buyer Signals", "Quick Local Brief", "Campaigns", "CRM Automation Notes"],
        crm_automation_triggers: ["emergency call", "estimate not closed", "water heater quote", "annual inspection", "new homeowner touch"]
      },
      "painting" => {
        label: "Painting",
        category: "home services",
        keywords: %w[painting painter paint cabinet-refinishing cabinet repaint],
        input_variables: ["interior vs exterior mix", "cabinet or specialty focus", "HOA relevance", "materials and surfaces", "before/after assets"],
        targeting_definition: "Prioritize homes likely due for repaint cycles, HOA curb-appeal pressure, high-value exterior visibility, and real estate turnover.",
        intelligence_tasks: ["service and seasonal snapshot", "exterior condition and climate", "repaint-cycle targeting", "premium curb-appeal areas", "real estate turnover", "quick local brief", "campaign proposals", "CRM automation opportunities"],
        campaign_types: ["Curb Appeal Spring", "HOA Blitz", "Cabinet Refresh", "New Homebuyer Interior", "Seasonal Booking", "Before/After Showcase", "Brick by Brick"],
        output_sections: ["Client & Focus", "Seasonal Paint Window", "Repaint Cycle Targeting", "Curb Appeal Neighborhoods", "Real Estate Turnover", "Quick Local Brief", "Campaigns", "CRM Automation Notes"],
        crm_automation_triggers: ["estimate sent", "before/after available", "seasonal waitlist", "past project anniversary", "new homeowner touch"]
      },
      "pressure_washing" => {
        label: "Pressure Washing",
        category: "home services",
        keywords: ["pressure washing", "pressure-washing", "power washing", "soft wash", "softwash", "exterior cleaning"],
        input_variables: ["residential vs commercial mix", "surface specialties", "recurring service model", "HOA or curb appeal markets", "commercial corridor targets"],
        targeting_definition: "Prioritize homes and businesses affected by humidity, tree canopy, HOA standards, visible exterior surfaces, and pre-listing curb appeal needs.",
        intelligence_tasks: ["service and seasonal snapshot", "climate/staining factors", "HOA and curb appeal targeting", "commercial corridor targeting", "pre-listing demand", "quick local brief", "campaign proposals", "CRM automation opportunities"],
        campaign_types: ["HOA Curb Appeal", "Annual Wash Reminder", "Roof Soft Wash", "Commercial Recurring Route", "Prelisting Clean-Up", "Neighbor Showcase"],
        output_sections: ["Client & Focus", "Exterior Cleaning Demand", "HOA & Curb Appeal Signals", "Commercial Route Targets", "Listing Prep Opportunity", "Quick Local Brief", "Campaigns", "CRM Automation Notes"],
        crm_automation_triggers: ["annual reminder", "estimate sent", "seasonal pollen/algae window", "commercial route follow-up", "before/after available"]
      },
      "landscaping_lawn_care" => {
        label: "Landscaping & Lawn Care",
        category: "home services",
        keywords: %w[landscaping landscape lawn mowing mow irrigation hardscape turf],
        input_variables: ["maintenance vs project mix", "lot-size targets", "growing zone", "irrigation or hardscape capability", "route-density goals"],
        targeting_definition: "Prioritize route density, lot size, seasonal cleanup demand, new homeowner needs, and neighborhoods where curb appeal drives recurring revenue.",
        intelligence_tasks: ["service and seasonal snapshot", "growing-zone timing", "route-density targeting", "lot-size and curb-appeal targeting", "new homeowner and new construction signals", "quick local brief", "campaign proposals", "CRM automation opportunities"],
        campaign_types: ["Route Density Buildout", "Seasonal Cleanup", "Maintenance Plan Push", "Hardscape Upgrade", "New Homeowner Yard Reset", "HOA Neighborhood Campaign"],
        output_sections: ["Client & Focus", "Seasonal Lawn Window", "Route Density", "Lot & Curb Appeal Targeting", "Growth Signals", "Quick Local Brief", "Campaigns", "CRM Automation Notes"],
        crm_automation_triggers: ["seasonal cleanup due", "maintenance plan renewal", "estimate sent", "route neighbor prospect", "new homeowner touch"]
      },
      "pest_control" => {
        label: "Pest Control",
        category: "home services",
        keywords: %w[pest termite exterminator crawlspace mosquito rodent bugs],
        input_variables: ["recurring plan model", "termite or pest specialties", "construction type", "service radius", "seasonal pest pressure"],
        targeting_definition: "Prioritize pest pressure, termite risk, crawlspace or foundation signals, new construction displacement, and new homeowner prevention needs.",
        intelligence_tasks: ["service and seasonal snapshot", "local pest pressure", "termite/foundation targeting", "new construction displacement", "new homeowner opportunity", "quick local brief", "campaign proposals", "CRM automation opportunities"],
        campaign_types: ["Seasonal Pest Calendar", "Termite Bond", "Crawlspace/Foundation Check", "New Construction Displacement", "New Homebuyer Protection", "Recurring Plan Push"],
        output_sections: ["Client & Focus", "Pest Pressure", "Termite & Foundation Signals", "New Construction Risk", "New Homebuyer Opportunity", "Quick Local Brief", "Campaigns", "CRM Automation Notes"],
        crm_automation_triggers: ["seasonal pest alert", "renewal due", "inspection completed", "termite quote", "new homeowner touch"]
      },
      "tree_service" => {
        label: "Tree Service",
        category: "home services",
        keywords: %w[tree arborist stump canopy trimming pruning removal],
        input_variables: ["service mix", "equipment capability", "storm response", "utility vegetation work", "lot-clearing capability"],
        targeting_definition: "Prioritize mature canopy neighborhoods, storm exposure, tree disease alerts, utility clearance needs, and lot clearing growth areas.",
        intelligence_tasks: ["service and seasonal snapshot", "storm and canopy risk", "mature neighborhood targeting", "disease/pest alert logic", "lot clearing and growth areas", "quick local brief", "campaign proposals", "CRM automation opportunities"],
        campaign_types: ["Storm Prep", "Mature Canopy Safety", "Disease/Pest Alert", "Post-Storm Response", "Lot Clearing", "Brick by Brick"],
        output_sections: ["Client & Focus", "Storm & Canopy Risk", "Mature Neighborhoods", "Tree Health Signals", "Growth & Lot Clearing", "Quick Local Brief", "Campaigns", "CRM Automation Notes"],
        crm_automation_triggers: ["storm alert", "estimate sent", "annual tree check", "neighbor of recent job", "post-storm follow-up"]
      },
      "garage_concrete_coatings" => {
        label: "Garage & Concrete Coatings",
        category: "home services",
        keywords: ["garage", "concrete coating", "concrete coatings", "epoxy", "polyaspartic", "floor coating"],
        input_variables: ["residential vs commercial mix", "garage size focus", "coating system", "lifestyle angle", "builder/new home gaps"],
        targeting_definition: "Prioritize newer-to-established homes with garage upgrade potential, lifestyle storage needs, commercial floors, and properties where builder-grade concrete is ready for improvement.",
        intelligence_tasks: ["service and seasonal snapshot", "garage/lifestyle demand", "new home upgrade targeting", "established neighborhood upgrades", "commercial floor opportunities", "quick local brief", "campaign proposals", "CRM automation opportunities"],
        campaign_types: ["New Home Garage Upgrade", "Lifestyle Garage", "Established Neighborhood Upgrade", "Commercial Floor Refresh", "Builder Gap", "Before/After Showcase"],
        output_sections: ["Client & Focus", "Garage Upgrade Demand", "New Home Targeting", "Established Neighborhoods", "Commercial Opportunity", "Quick Local Brief", "Campaigns", "CRM Automation Notes"],
        crm_automation_triggers: ["estimate sent", "new homeowner touch", "before/after available", "garage season push", "commercial quote follow-up"]
      },
      "cleaning_services" => {
        label: "Cleaning Services",
        category: "home services",
        keywords: %w[cleaning cleaner maid janitorial housekeeping airbnb str turnover],
        input_variables: ["residential vs commercial mix", "recurring model", "move-in/move-out focus", "short-term rental focus", "commercial corridor targets"],
        targeting_definition: "Prioritize recurring residential demand, move-in/move-out events, STR turnover, offices/commercial corridors, and realtor referral moments.",
        intelligence_tasks: ["service and seasonal snapshot", "recurring household targeting", "move-in/move-out demand", "STR and rental turnover", "commercial corridor opportunities", "quick local brief", "campaign proposals", "CRM automation opportunities"],
        campaign_types: ["Recurring Residential", "Move-In Move-Out", "STR Turnover", "Office/Commercial Cleaning", "Realtor Referral", "Seasonal Deep Clean"],
        output_sections: ["Client & Focus", "Recurring Demand", "Move & Turnover Signals", "Rental/STR Opportunity", "Commercial Targets", "Quick Local Brief", "Campaigns", "CRM Automation Notes"],
        crm_automation_triggers: ["recurring renewal", "move date", "missed booking", "commercial quote", "seasonal deep clean"]
      },
      "fencing" => {
        label: "Fencing",
        category: "home services",
        keywords: %w[fence fencing gate vinyl wood aluminum chainlink],
        input_variables: ["fence types", "lot size", "pet/pool/HOA drivers", "storm damage capacity", "new build relevance"],
        targeting_definition: "Prioritize 15-20 year fence replacement, pet and pool safety needs, HOA community standards, storm damage, and new homeowner yard upgrades.",
        intelligence_tasks: ["service and seasonal snapshot", "fence age/replacement targeting", "pet and pool safety targeting", "HOA community targeting", "storm damage and new builds", "quick local brief", "campaign proposals", "CRM automation opportunities"],
        campaign_types: ["Fence Replacement", "Pet & Yard Safety", "Pool Safety", "New Homebuyer Yard", "HOA Community", "Storm Damage"],
        output_sections: ["Client & Focus", "Fence Replacement Signals", "Safety & Lifestyle Drivers", "HOA Neighborhoods", "Storm & New Build Demand", "Quick Local Brief", "Campaigns", "CRM Automation Notes"],
        crm_automation_triggers: ["estimate sent", "storm follow-up", "pool season", "new homeowner touch", "HOA neighborhood route"]
      },
      "windows_doors" => {
        label: "Windows & Doors",
        category: "home services",
        keywords: ["windows", "window", "doors", "door", "replacement windows", "entry door", "impact windows"],
        input_variables: ["product focus", "franchise or independent", "energy/code relevance", "impact zone", "financing or rebate angle"],
        targeting_definition: "Prioritize window age by home era, energy cost pressure, impact/code zones, curb appeal entry door opportunities, and new homeowner comfort upgrades.",
        intelligence_tasks: ["service and seasonal snapshot", "energy/code pressure", "window age targeting", "impact/weather zone targeting", "new homeowner upgrades", "quick local brief", "campaign proposals", "CRM automation opportunities"],
        campaign_types: ["Window Age Targeting", "Energy Savings", "Impact Code Awareness", "Curb Appeal Door", "New Homeowner Comfort", "Seasonal Comfort"],
        output_sections: ["Client & Focus", "Energy & Code Signals", "Window Age Targeting", "Weather/Impact Opportunity", "New Homeowner Upgrades", "Quick Local Brief", "Campaigns", "CRM Automation Notes"],
        crm_automation_triggers: ["estimate sent", "energy season", "storm/code alert", "new homeowner touch", "financing follow-up"]
      },
      "remodeling_general_contracting" => {
        label: "Remodeling & General Contracting",
        category: "home services",
        keywords: %w[remodel remodeling renovation contractor contracting kitchen bath bathroom addition],
        input_variables: ["specialties", "market position", "permit trends", "kitchen/bath focus", "aging-in-place capability"],
        targeting_definition: "Prioritize 15-20 year kitchen/bath refresh cycles, permit and remodel trend signals, new homeowner renovation needs, and aging-in-place households.",
        intelligence_tasks: ["service and seasonal snapshot", "permit/remodel demand", "kitchen/bath cycle targeting", "new homeowner renovation signals", "aging-in-place opportunities", "quick local brief", "campaign proposals", "CRM automation opportunities"],
        campaign_types: ["Kitchen/Bath Refresh", "New Homebuyer Renovation", "Aging-in-Place", "Permit/Trend Campaign", "Design Consultation", "Seasonal Planning"],
        output_sections: ["Client & Focus", "Remodel Demand", "Kitchen/Bath Cycle", "New Homeowner Signals", "Aging-in-Place Opportunity", "Quick Local Brief", "Campaigns", "CRM Automation Notes"],
        crm_automation_triggers: ["consult booked", "estimate sent", "design review", "new homeowner touch", "seasonal planning"]
      },
      "electrical" => {
        label: "Electrical",
        category: "home services",
        keywords: %w[electric electrical electrician panel generator ev-charger charger wiring],
        input_variables: ["service vs project mix", "license/service capacity", "panel upgrade focus", "generator work", "EV charger work"],
        targeting_definition: "Prioritize older panels, pre-1990 homes, aluminum wiring risk, outage/generator concern, EV charger demand, and safety inspection moments.",
        intelligence_tasks: ["service and seasonal snapshot", "panel/wiring age targeting", "grid reliability and outage risk", "EV charger opportunity", "safety inspection demand", "quick local brief", "campaign proposals", "CRM automation opportunities"],
        campaign_types: ["Panel Upgrade", "EV Charger", "Generator Backup", "Safety Inspection", "Old Home Electrical", "Storm/Outage Preparedness"],
        output_sections: ["Client & Focus", "Electrical Safety Signals", "Panel Age Targeting", "Outage & Generator Opportunity", "EV Charger Demand", "Quick Local Brief", "Campaigns", "CRM Automation Notes"],
        crm_automation_triggers: ["estimate sent", "inspection completed", "storm/outage alert", "EV charger inquiry", "old home follow-up"]
      },
      "solar" => {
        label: "Solar",
        category: "home services",
        keywords: %w[solar photovoltaic pv net-metering inverter energy],
        input_variables: ["product and financing model", "utility territory", "incentives", "roof partner need", "solar plus storage capability"],
        targeting_definition: "Prioritize high-ROI roofs, utility rate pressure, incentive timing, solar adoption clusters, and homes where roof condition may create a solar-plus-roofing opportunity.",
        intelligence_tasks: ["service and seasonal snapshot", "utility rate/incentive logic", "high-ROI roof targeting", "solar adoption zones", "roof condition disqualifier/opportunity", "quick local brief", "campaign proposals", "CRM automation opportunities"],
        campaign_types: ["High-ROI Solar", "Incentive Urgency", "Neighborhood Adoption", "Solar + Roof", "Energy Bill Review", "Battery/Backup Awareness"],
        output_sections: ["Client & Focus", "Utility & Incentive Signals", "Solar ROI Targeting", "Adoption Clusters", "Roof Readiness", "Quick Local Brief", "Campaigns", "CRM Automation Notes"],
        crm_automation_triggers: ["proposal sent", "utility bill uploaded", "incentive deadline", "roof review", "neighbor adoption campaign"]
      },
      "flooring" => {
        label: "Flooring",
        category: "home services",
        keywords: %w[floor flooring carpet tile hardwood laminate lvp vinyl],
        input_variables: ["flooring types", "showroom or mobile model", "residential vs commercial mix", "real estate turnover", "condo/multifamily relevance"],
        targeting_definition: "Prioritize carpet replacement cycles, style refresh demand, pre-listing improvements, move-in flooring, condo sound-code needs, and commercial refresh opportunities.",
        intelligence_tasks: ["service and seasonal snapshot", "floor age and style trends", "carpet replacement targeting", "real estate turnover", "condo/multifamily and commercial opportunities", "quick local brief", "campaign proposals", "CRM automation opportunities"],
        campaign_types: ["Carpet Replacement", "Prelisting Floor Refresh", "Move-In Flooring", "Condo Sound Code", "Commercial Refresh", "Style Trend Upgrade"],
        output_sections: ["Client & Focus", "Flooring Demand", "Replacement Cycle Targeting", "Real Estate Turnover", "Commercial/Multifamily Opportunity", "Quick Local Brief", "Campaigns", "CRM Automation Notes"],
        crm_automation_triggers: ["estimate sent", "move date", "prelisting request", "style consult", "commercial quote"]
      },
      FALLBACK_KEY => {
        label: "Local Services",
        category: "local services",
        keywords: [],
        input_variables: ["service category", "service area", "target customer", "seasonality", "CRM stage", "best contact path"],
        targeting_definition: "Use known service, geography, customer, and timing data from CRM. If the industry is unclear, do not pretend to know industry-specific permit, weather, or property facts.",
        intelligence_tasks: ["source fact summary", "local timing logic", "customer segment fit", "campaign channel fit", "contact path and CRM next step", "quick local brief", "campaign proposals", "CRM automation opportunities"],
        campaign_types: ["Neighborhood Blitz", "New Homebuyer Outreach", "Seasonal Offer", "Past Customer Reactivation", "EDDM ZIP Saturation", "Brick by Brick"],
        output_sections: ["Client & Focus", "Known Source Facts", "Local Opportunity", "Target Customer Fit", "Campaign Recommendations", "Quick Local Brief", "CRM Automation Notes"],
        crm_automation_triggers: ["recent inquiry", "estimate sent", "no recent contact", "new customer", "seasonal follow-up"]
      }
    }.freeze

    def options
      [{ value: AUTO_VALUE, label: "AUTO DETECT" }] +
        PROFILES.except(FALLBACK_KEY).map { |key, profile| { value: key, label: profile.fetch(:label).upcase } }
    end

    def normalize(value)
      key = value.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
      return AUTO_VALUE if key.blank? || key == AUTO_VALUE

      normalized = aliases.fetch(key, key)
      PROFILES.key?(normalized) ? normalized : AUTO_VALUE
    end

    def payload_for(value = AUTO_VALUE, crm_record: nil, labeled: {}, raw: {}, company_name: nil, industry: nil, services: nil, audience: nil)
      requested = normalize(value)
      detected = requested != AUTO_VALUE && PROFILES.key?(requested) ? requested : detect_key(crm_record, labeled, raw, company_name, industry, services)
      profile = PROFILES.fetch(detected, PROFILES.fetch(FALLBACK_KEY))

      {
        "selected" => requested,
        "industry" => detected,
        "label" => profile.fetch(:label),
        "category" => profile.fetch(:category),
        "confidence" => confidence_for(requested, detected),
        "input_variables" => profile.fetch(:input_variables),
        "targeting_definition" => profile.fetch(:targeting_definition),
        "intelligence_tasks" => profile.fetch(:intelligence_tasks),
        "campaign_types" => profile.fetch(:campaign_types),
        "output_sections" => profile.fetch(:output_sections),
        "crm_automation_triggers" => profile.fetch(:crm_automation_triggers),
        "mode_guidance" => mode_guidance(audience, profile),
        "data_policy" => data_policy,
        "source" => "wizwiki_industry_strategy_prompts_v2"
      }
    end

    def detect_key(crm_record, labeled, raw, company_name, industry, services)
      haystack = [
        company_name,
        industry,
        services,
        crm_record&.name,
        crm_record&.domain,
        crm_record&.stage,
        labeled.to_h.values,
        raw.to_h.values
      ].flatten.compact.join(" ").downcase

      PROFILES.except(FALLBACK_KEY).find do |_key, profile|
        profile.fetch(:keywords).any? { |keyword| haystack.include?(keyword.to_s.downcase) }
      end&.first || FALLBACK_KEY
    end

    def confidence_for(requested, detected)
      return "explicit" if requested != AUTO_VALUE && requested == detected
      return "detected" if detected != FALLBACK_KEY

      "fallback"
    end

    def mode_guidance(audience, profile)
      case audience.to_s
      when "am"
        "Use #{profile.fetch(:label)} tasks to create AM-ready questions, gaps, and next moves. It is acceptable to list missing research needs, but do not invent facts."
      when "copy_maker"
        "Use #{profile.fetch(:label)} campaign families to make specific messages. Only reference facts present in CRM, Fathom/playbook, media, or trained context."
      else
        "Use #{profile.fetch(:label)} strategy to make the report feel specific and useful. Keep unsupported research private or phrase it as a recommended verification step."
      end
    end

    def data_policy
      {
        "do_not_invent" => ["weather events", "utility rates", "permit counts", "exact market percentages", "ZIP rankings", "competitor claims"],
        "client_mode" => "Use confident, client-safe recommendations from known data. Omit or soften missing facts.",
        "am_mode" => "Call out missing inputs and recommended research tasks for the account manager.",
        "copy_mode" => "Do not include internal research gaps in customer-facing copy."
      }
    end

    def aliases
      {
        "lawn_care" => "landscaping_lawn_care",
        "landscaping" => "landscaping_lawn_care",
        "pressure_wash" => "pressure_washing",
        "power_washing" => "pressure_washing",
        "garage" => "garage_concrete_coatings",
        "concrete_coatings" => "garage_concrete_coatings",
        "cleaning" => "cleaning_services",
        "tree" => "tree_service",
        "windows" => "windows_doors",
        "doors" => "windows_doors",
        "remodeling" => "remodeling_general_contracting",
        "general_contracting" => "remodeling_general_contracting"
      }
    end
  end
end
