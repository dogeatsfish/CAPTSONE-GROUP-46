import { useEffect, useState } from "react";
import { listDatasets } from "../api/client";

// Fetches the fixed list of available MBO data files once on mount. Datasets
// are pre-generated .bin files on disk (see sw/data_pipeline/data) -- nothing
// here generates new data, it only surfaces what's already there to pick from.
export function useDatasets() {
    const [datasets, setDatasets] = useState([]);
    const [loading, setLoading] = useState(true);
    const [error, setError] = useState(null);

    useEffect(() => {
        let cancelled = false;

        listDatasets()
            .then((data) => {
                if (cancelled) return;
                setDatasets(data.datasets || []);
            })
            .catch((e) => {
                if (cancelled) return;
                setError(String(e.message || e));
            })
            .finally(() => {
                if (!cancelled) setLoading(false);
            });

        return () => {
            cancelled = true;
        };
    }, []);

    return { datasets, loading, error };
}
