import React, { useEffect } from 'react';
import { BrowserRouter, Switch, Route, useLocation } from "react-router-dom";

import Dash from './index'
import SourcesModal from './stats/modals/sources'
import ReferrersDrilldownModal from './stats/modals/referrer-drilldown'
import GoogleKeywordsModal from './stats/modals/google-keywords'
import PagesModal from './stats/modals/pages'
import EntryPagesModal from './stats/modals/entry-pages'
import ExitPagesModal from './stats/modals/exit-pages'
import ModalTable from './stats/modals/table'
import PropsModal from './stats/modals/props'
import ConversionsModal from './stats/modals/conversions'
import FilterModal from './stats/modals/filter-modal'
import * as url from './util/url';

function ScrollToTop() {
  const location = useLocation();

  useEffect(() => {
    if (location.state && location.state.scrollTop) {
      window.scrollTo(0, 0);
    }
  }, [location]);

  return null;
}

export default function Router({ site, loggedIn, currentUserRole }) {
  return (
    <BrowserRouter basename={site.shared ? `/share/${encodeURIComponent(site.domain)}` : encodeURIComponent(site.domain)}>
      <Route path="/">
        <ScrollToTop />
        <Dash site={site} loggedIn={loggedIn} currentUserRole={currentUserRole} />
        <Switch>
          <Route exact path={["/sources", "/utm_mediums", "/utm_sources", "/utm_campaigns", "/utm_contents", "/utm_terms"]}>
            <SourcesModal site={site} />
          </Route>
          <Route exact path="/referrers/Google">
            <GoogleKeywordsModal site={site} />
          </Route>
          <Route exact path="/referrers/:referrer">
            <ReferrersDrilldownModal site={site} />
          </Route>
          <Route path="/pages">
            <PagesModal site={site} />
          </Route>
          <Route path="/entry-pages">
            <EntryPagesModal site={site} />
          </Route>
          <Route path="/exit-pages">
            <ExitPagesModal site={site} />
          </Route>
          <Route path="/countries">
            <ModalTable title="Top countries" site={site} endpoint={url.apiPath(site, '/countries')} filterKey="country" keyLabel="Country" renderIcon={renderCountryIcon} showPercentage={true} />
          </Route>
          <Route path="/regions">
            <ModalTable title="Top regions" site={site} endpoint={url.apiPath(site, '/regions')} filterKey="region" keyLabel="Region" renderIcon={renderRegionIcon} />
          </Route>
          <Route path="/cities">
            <ModalTable title="Top cities" site={site} endpoint={url.apiPath(site, '/cities')} filterKey="city" keyLabel="City" renderIcon={renderCityIcon} />
          </Route>
          <Route path="/custom-prop-values/:prop_key">
            <PropsModal site={site} />
          </Route>
          <Route path="/conversions">
            <ConversionsModal site={site} />
          </Route>
          <Route path={["/filter/:field"]}>
            <FilterModal site={site} />
          </Route>
        </Switch>
      </Route>
    </BrowserRouter >
  );
}

function renderCityIcon(city) {
  return <span className="mr-1">{city.country_flag}</span>
}

function renderCountryIcon(country) {
  return <span className="mr-1">{country.flag}</span>
}

function renderRegionIcon(region) {
  return <span className="mr-1">{region.country_flag}</span>
}
